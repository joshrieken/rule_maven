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
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Repo
  alias RuleMaven.Users.User
  alias RuleMaven.Voices.GameVoice
  alias RuleMaven.Progress.{GameMastery, MasteryEvent}

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
    * `{:duplicate, %GameMastery{}}` — this user already earned for `source_key`
    * `{:error, term}`
  """
  def award_ask(user_id, game_id, source_key)
      when is_integer(user_id) and is_integer(game_id) and is_binary(source_key) do
    award(user_id, game_id, source_key, "ask", @ask_mastery_xp)
  end

  defp award(user_id, game_id, source_key, kind, xp_delta) do
    event_attrs = %{
      user_id: user_id,
      game_id: game_id,
      source_key: source_key,
      kind: kind,
      xp: xp_delta
    }

    txn =
      Repo.transaction(fn ->
        case Repo.insert(MasteryEvent.changeset(%MasteryEvent{}, event_attrs)) do
          {:ok, _event} ->
            bump_global(user_id)
            apply_mastery(user_id, game_id, xp_delta)

          {:error, changeset} ->
            if duplicate_source_key?(changeset) do
              Repo.rollback(:duplicate)
            else
              Repo.rollback({:changeset, changeset})
            end
        end
      end)

    case txn do
      {:ok, result} -> {:awarded, result}
      {:error, :duplicate} -> {:duplicate, get_mastery(user_id, game_id)}
      {:error, other} -> {:error, other}
    end
  end

  defp bump_global(user_id) do
    Repo.update_all(from(u in User, where: u.id == ^user_id),
      inc: [curator_points: @event_curator_points]
    )
  end

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
      unlocked = unlockable_slugs(game_id, prev_level + 1, new_level, mastery.unlocked_voice_slugs)

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
