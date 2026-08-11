defmodule RuleMaven.Progress do
  @moduledoc """
  Per-game mastery progression — the single funnel for earning XP.

  One economy: every earning event bumps BOTH the global `users.curator_points`
  (coarse, +1, same scale as a settled vote so existing badge thresholds stay
  meaningful) AND the per-game `game_mastery` bar (fine-grained, drives the
  level curve). Same events, two granularities — never a parallel currency.

  The `mastery_events` unique index on `(user_id, source_key)` is the per-user
  anti-farm dedupe: a user earns at most once per canonical answer, so cache
  hits that are new *to them* still count, but their own repeats award nothing.

  ## The `:mastery_levels` flag

  The flag gates *applying* XP, never *recording* it. With the flag off an
  earning event is still written, with `applied_at: nil` — the ledger keeps
  accruing invisibly. Turning the flag on runs `backfill_pending/0`, which
  folds every banked event into `game_mastery` and `curator_points`, so a user
  levels up for everything they did while the feature was dark.

  Gating the application (rather than just hiding the bar) matters because
  levelling has side effects outside the bar: global `curator_points` feed
  badge thresholds, and crossing a level grants persona unlocks.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Flags
  alias RuleMaven.Progress.{GameMastery, MasteryEvent}
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Users.User
  alias RuleMaven.Voices.GameVoice

  # Mastery XP granted for one new-to-you, confident, cited answer. Drives the
  # per-game bar and the level curve.
  @ask_mastery_xp 15
  # Global currency bump per meaningful event — same scale as a settled vote so
  # curator badge thresholds (5/10/25) keep their meaning.
  @event_curator_points 1

  @doc """
  Awards mastery for a confident, cited answer that is new to this user.

  `source_key` is the canonical answer identity (`pool_source_id || id`). The
  caller is responsible for the trust guard: only call this for answers that are
  not refused/errored and are citation-backed.

  Returns:
    * `{:awarded, result}` where `result` is
      `%{game_mastery: %GameMastery{}, xp_delta: pos_integer,
         level_up: boolean, unlocked: [slug]}`
    * `{:deferred, %GameMastery{}}` — `:mastery_levels` is off for this user, so
      the event was banked for a later `backfill_pending/0` and nothing changed
    * `{:duplicate, %GameMastery{}}` — this user already earned for `source_key`
    * `{:error, term}`
  """
  def award_ask(user_id, game_id, source_key)
      when is_integer(user_id) and is_integer(game_id) and is_binary(source_key) do
    award(user_id, game_id, source_key, "ask", @ask_mastery_xp)
  end

  defp award(user_id, game_id, source_key, kind, xp_delta) do
    apply? = levelling_on?(user_id)

    event_attrs = %{
      user_id: user_id,
      game_id: game_id,
      source_key: source_key,
      kind: kind,
      xp: xp_delta,
      applied_at: if(apply?, do: now())
    }

    txn =
      Repo.transaction(fn ->
        %MasteryEvent{}
        |> MasteryEvent.changeset(event_attrs)
        |> Repo.insert()
        |> banked_or_applied(user_id, game_id, xp_delta, apply?)
      end)

    case txn do
      {:ok, :deferred} -> {:deferred, get_mastery(user_id, game_id)}
      {:ok, result} -> {:awarded, result}
      {:error, :duplicate} -> {:duplicate, get_mastery(user_id, game_id)}
      {:error, other} -> {:error, other}
    end
  end

  # Runs inside `award/5`'s transaction. `apply?` false means the event is
  # banked only — it stays in the ledger with `applied_at: nil` until a
  # backfill folds it in.
  defp banked_or_applied({:ok, _event}, _user_id, _game_id, _xp_delta, false), do: :deferred

  defp banked_or_applied({:ok, _event}, user_id, game_id, xp_delta, true) do
    bump_global(user_id, 1)
    apply_mastery(user_id, game_id, xp_delta)
  end

  defp banked_or_applied({:error, changeset}, _user_id, _game_id, _xp_delta, _apply?) do
    if duplicate_source_key?(changeset) do
      Repo.rollback(:duplicate)
    else
      Repo.rollback({:changeset, changeset})
    end
  end

  @doc """
  Whether levelling currently applies for `user_id`. Resolves the flag against
  the user so actor grants and percentage rollouts work, not just the boolean.
  """
  def levelling_on?(user_id) when is_integer(user_id) do
    Flags.enabled?(:mastery_levels, Users.get_user(user_id))
  end

  def levelling_on?(_), do: Flags.enabled?(:mastery_levels, nil)

  @doc """
  Applies every banked (`applied_at IS NULL`) event for users who now have
  `:mastery_levels` on. Idempotent and safe to run on a schedule: users still
  gated off are skipped and their events stay banked.

  Returns `%{users: n, events: m}`.
  """
  def backfill_pending do
    pending_user_ids()
    |> Enum.filter(&levelling_on?/1)
    |> Enum.reduce(%{users: 0, events: 0}, fn user_id, acc ->
      case apply_pending(user_id) do
        {:ok, %{events: 0}} -> acc
        {:ok, %{events: n}} -> %{users: acc.users + 1, events: acc.events + n}
      end
    end)
  end

  @doc """
  Folds one user's banked events into their per-game bars and global points,
  ignoring the flag (the caller decides). Only events banked at call time are
  applied — anything inserted mid-run is left for the next pass.

  Returns `{:ok, %{events: n, games: [result]}}` where each `result` has the
  same shape as an `{:awarded, result}` payload.
  """
  def apply_pending(user_id) when is_integer(user_id) do
    event_ids =
      Repo.all(
        from e in MasteryEvent,
          where: e.user_id == ^user_id and is_nil(e.applied_at),
          select: e.id
      )

    if event_ids == [] do
      {:ok, %{events: 0, games: []}}
    else
      per_game =
        Repo.all(
          from e in MasteryEvent,
            where: e.id in ^event_ids,
            group_by: e.game_id,
            select: {e.game_id, sum(e.xp), count(e.id)}
        )

      results =
        Enum.map(per_game, fn {game_id, xp, _count} ->
          apply_mastery(user_id, game_id, xp)
        end)

      bump_global(user_id, length(event_ids))

      Repo.update_all(from(e in MasteryEvent, where: e.id in ^event_ids),
        set: [applied_at: now()]
      )

      {:ok, %{events: length(event_ids), games: results}}
    end
  end

  @doc "How many earning events are banked but not yet applied, across all users."
  def pending_count do
    Repo.aggregate(from(e in MasteryEvent, where: is_nil(e.applied_at)), :count, :id)
  end

  defp pending_user_ids do
    Repo.all(
      from e in MasteryEvent,
        where: is_nil(e.applied_at),
        distinct: true,
        select: e.user_id
    )
  end

  defp bump_global(user_id, count) when count > 0 do
    Repo.update_all(from(u in User, where: u.id == ^user_id),
      inc: [curator_points: @event_curator_points * count]
    )
  end

  defp bump_global(_user_id, _count), do: {0, nil}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Atomically bumps the per-game bar (on_conflict inc is race-safe across
  # concurrent awards for different source_keys), then recomputes level and
  # grants any personas whose unlock_level was crossed.
  defp apply_mastery(user_id, game_id, xp_delta) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %GameMastery{
        user_id: user_id,
        game_id: game_id,
        xp: xp_delta,
        level: 0,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [inc: [xp: xp_delta], set: [updated_at: now]],
      conflict_target: [:user_id, :game_id]
    )

    mastery = get_mastery(user_id, game_id)
    prev_level = mastery.level
    new_level = level_for(mastery.xp)

    if new_level > prev_level do
      unlocked =
        unlockable_slugs(game_id, prev_level + 1, new_level, mastery.unlocked_voice_slugs)

      {:ok, updated} =
        Repo.update(
          GameMastery.changeset(mastery, %{
            level: new_level,
            unlocked_voice_slugs: mastery.unlocked_voice_slugs ++ unlocked
          })
        )

      %{game_mastery: updated, xp_delta: xp_delta, level_up: true, unlocked: unlocked}
    else
      %{game_mastery: mastery, xp_delta: xp_delta, level_up: false, unlocked: []}
    end
  end

  @doc """
  The per-game mastery row for a user, or a zeroed virtual struct if none yet.
  Never nil, so callers can render a bar unconditionally.
  """
  def get_mastery(user_id, game_id) do
    Repo.get_by(GameMastery, user_id: user_id, game_id: game_id) ||
      %GameMastery{user_id: user_id, game_id: game_id, xp: 0, level: 0, unlocked_voice_slugs: []}
  end

  @doc """
  Level for a cumulative XP total. Thresholds rise as `25·n·(n+1)`:
  Lv1 @ 50, Lv2 @ 150, Lv3 @ 300, Lv4 @ 500, …  Level 0 below 50.
  """
  def level_for(xp) when is_integer(xp) and xp >= 0 do
    level_for(xp, 1)
  end

  defp level_for(xp, n) do
    if xp >= threshold(n), do: level_for(xp, n + 1), else: n - 1
  end

  @doc "Cumulative XP required to reach `level` (`level >= 1`)."
  def threshold(level) when is_integer(level) and level >= 1 do
    25 * level * (level + 1)
  end

  @doc "XP into the current level and XP the current level spans, for the bar fill."
  def level_progress(xp) when is_integer(xp) and xp >= 0 do
    level = level_for(xp)
    floor = if level == 0, do: 0, else: threshold(level)
    ceil = threshold(level + 1)
    %{level: level, into: xp - floor, span: ceil - floor}
  end

  # Slugs of this game's personas whose unlock_level falls in lo..hi and that the
  # user hasn't already unlocked.
  defp unlockable_slugs(game_id, lo, hi, already) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id and gv.unlock_level >= ^lo and gv.unlock_level <= ^hi,
        select: gv.slug
    )
    |> Enum.reject(&(&1 in already))
  end

  defp duplicate_source_key?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:user_id, {_msg, opts}} -> opts[:constraint] == :unique
      {_field, {_msg, opts}} -> opts[:constraint] == :unique
    end)
  end
end
