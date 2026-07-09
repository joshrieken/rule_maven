defmodule RuleMaven.HouseRules do
  @moduledoc """
  House-rule variants users log per game. Each rule gets an async LLM check
  classifying it against rules-as-written (see Workers.HouseRuleCheckWorker).
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Games.{HouseRule, HouseRuleDelta, QuestionLog}
  alias RuleMaven.{Games, Security, Workers}

  # Rules whose body embeds within this cosine similarity of a question's
  # embedding are surfaced as an overlay under that answer. Rule↔question
  # relatedness sits far below the near-duplicate band the answer pool uses
  # (0.92): measured on a real rule ("domestic trades must be 1-for-1 value"),
  # on-topic questions score 0.42–0.54 and off-topic ones ≤0.29, so 0.35 splits
  # the bands with margin on both sides. Admin-tunable via
  # `house_rule_overlay_similarity`.
  @default_overlay_similarity 0.35

  def get(id), do: Repo.get(HouseRule, id)

  def list_for_user(game_id, user_id) do
    Repo.all(
      from h in HouseRule,
        where: h.game_id == ^game_id and h.user_id == ^user_id,
        order_by: [desc: h.inserted_at]
    )
  end

  def community_for_game(game_id, exclude_user_id \\ nil) do
    base =
      from h in HouseRule,
        where:
          h.game_id == ^game_id and h.visibility == "community" and h.blocked == false,
        order_by: [desc: h.inserted_at]

    query =
      if exclude_user_id,
        do: from(h in base, where: h.user_id != ^exclude_user_id),
        else: base

    Repo.all(query)
  end

  def create(user, game_id, attrs) do
    %HouseRule{user_id: user.id, game_id: game_id}
    |> HouseRule.changeset(attrs)
    |> Repo.insert()
  end

  def update(%HouseRule{} = hr, attrs) do
    hr |> HouseRule.changeset(attrs) |> Repo.update()
  end

  def delete(%HouseRule{} = hr), do: Repo.delete(hr)

  def mark_checked(%HouseRule{} = hr, %{verdict: _} = results) do
    attrs =
      results
      |> Map.take([:verdict, :raw_quote, :check_note, :citations, :body_embedding])
      |> Map.merge(%{
        check_status: "done",
        checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    hr |> HouseRule.check_changeset(attrs) |> Repo.update()
  end

  def mark_failed(%HouseRule{} = hr, note) do
    hr
    |> HouseRule.check_changeset(%{check_status: "failed", check_note: note})
    |> Repo.update()
  end

  def mark_pending(%HouseRule{} = hr) do
    hr |> HouseRule.check_changeset(%{check_status: "pending"}) |> Repo.update()
  end

  def mark_stale_for_game(game_id) do
    {count, _} =
      Repo.update_all(
        from(h in HouseRule, where: h.game_id == ^game_id and h.check_status == "done"),
        set: [check_status: "stale"]
      )

    count
  end

  def set_blocked(%HouseRule{} = hr, blocked?) do
    hr
    |> Ecto.Changeset.change(blocked: blocked?)
    |> Repo.update()
  end

  @doc """
  Turn a rule on or off at the owner's own table. Owner-only.

  Independent of `visibility` (who else sees it) and `blocked` (admin removal).
  A disabled rule keeps its verdict, quote and embedding — flipping it back on
  costs no LLM call. `enabled` is deliberately absent from `HouseRule.changeset/2`
  so the edit form cannot mass-assign it.
  """
  def set_enabled(user, %HouseRule{} = hr, enabled?) when is_boolean(enabled?) do
    if hr.user_id == user.id do
      hr
      |> Ecto.Changeset.change(enabled: enabled?)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  UI entry point: guard (injection, rate limit) → insert → enqueue check.
  """
  def submit(user, game_id, attrs) do
    body = to_string(attrs["body"] || attrs[:body] || "")

    with :ok <- injection_guard(body),
         :ok <- Games.check_rate_limit(user),
         {:ok, hr} <- create(user, game_id, attrs) do
      enqueue_check(hr)
      {:ok, hr}
    end
  end

  @doc "Edit; re-checks (and re-bills) only when the body changed."
  def update_and_recheck(user, %HouseRule{} = hr, attrs) do
    if hr.user_id == user.id do
      new_body = to_string(attrs["body"] || attrs[:body] || hr.body)

      if new_body != hr.body do
        with :ok <- injection_guard(new_body),
             :ok <- Games.check_rate_limit(user),
             {:ok, hr} <- __MODULE__.update(hr, attrs),
             {:ok, hr} <- mark_pending(hr) do
          enqueue_check(hr)
          {:ok, hr}
        end
      else
        __MODULE__.update(hr, attrs)
      end
    else
      {:error, :not_owner}
    end
  end

  @doc "Re-check button for failed/stale rules. Counts against quota."
  def resubmit_check(user, %HouseRule{} = hr) do
    if hr.user_id == user.id do
      with :ok <- Games.check_rate_limit(user),
           {:ok, hr} <- mark_pending(hr) do
        enqueue_check(hr)
        {:ok, hr}
      end
    else
      {:error, :not_owner}
    end
  end

  # Overlay matching (Tier 0) --------------------------------------------
  #
  # Answers stay canonical RAW; a user's own checked rules that embed near the
  # question surface as a callout under the answer. Pure pgvector math — no
  # LLM cost per ask. Only `overrides`/`fills_gap` verdicts qualify: `matches`
  # rules can't change an answer and `unclear` ones have nothing reliable to say.

  @doc """
  The user's checked house rules relevant to a question embedding, nearest
  first. Returns [] for nil embeddings (question not embedded yet).
  """
  def overlay_rules(_user_id, _game_id, nil), do: []

  def overlay_rules(user_id, game_id, question_embedding) do
    distance = 1.0 - overlay_similarity()
    vec = Pgvector.new(question_embedding)

    Repo.all(
      from h in HouseRule,
        where: h.user_id == ^user_id and h.game_id == ^game_id,
        # A rule the owner switched off must not colour an answer.
        where: h.enabled == true,
        where: h.check_status == "done" and h.verdict in ["overrides", "fills_gap"],
        where: not is_nil(h.body_embedding),
        where: fragment("cosine_distance(?, ?::vector)", h.body_embedding, ^vec) <= ^distance,
        order_by: fragment("cosine_distance(?, ?::vector)", h.body_embedding, ^vec)
    )
  end

  defp overlay_similarity do
    case RuleMaven.Settings.get("house_rule_overlay_similarity") do
      nil ->
        @default_overlay_similarity

      "" ->
        @default_overlay_similarity

      val ->
        case Float.parse(val) do
          {f, _} -> f
          :error -> @default_overlay_similarity
        end
    end
  end

  # Delta notes (Tier 1) --------------------------------------------------

  @doc """
  Cache key hashes. The question side hashes the canonical wording so re-asks
  of the same normalized question share one delta; the rule side hashes the
  body so edits invalidate naturally.
  """
  def question_hash(%QuestionLog{} = ql) do
    sha256(ql.cleaned_question || ql.question || "")
  end

  def body_hash(%HouseRule{} = hr), do: sha256(hr.body || "")

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "Cached delta note for (rule, question), or nil."
  def get_delta(%HouseRule{} = hr, %QuestionLog{} = ql) do
    Repo.one(
      from d in HouseRuleDelta,
        where:
          d.house_rule_id == ^hr.id and
            d.question_hash == ^question_hash(ql) and
            d.rule_body_hash == ^body_hash(hr)
    )
  end

  @doc "Upsert a delta note (idempotent under worker retries)."
  def save_delta(%HouseRule{} = hr, %QuestionLog{} = ql, text) do
    %HouseRuleDelta{}
    |> HouseRuleDelta.changeset(%{
      house_rule_id: hr.id,
      question_hash: question_hash(ql),
      rule_body_hash: body_hash(hr),
      delta: text
    })
    |> Repo.insert(
      on_conflict: {:replace, [:delta, :updated_at]},
      conflict_target: [:house_rule_id, :question_hash, :rule_body_hash]
    )
  end

  @doc """
  User asks "how does my rule change this answer?". Cache hit is free and
  instant; a miss checks quota and enqueues the durable delta worker.
  Returns {:ok, delta} | :pending | {:error, reason}.
  """
  def request_delta(user, %HouseRule{} = hr, %QuestionLog{} = ql) do
    cond do
      hr.user_id != user.id ->
        {:error, :not_owner}

      delta = get_delta(hr, ql) ->
        {:ok, delta}

      true ->
        with :ok <- Games.check_rate_limit(user) do
          %{"house_rule_id" => hr.id, "question_log_id" => ql.id}
          |> Workers.HouseRuleDeltaWorker.new()
          |> Oban.insert()

          :pending
        end
    end
  end

  defp injection_guard(body) do
    if Security.prompt_injection?(body), do: {:error, :injection}, else: :ok
  end

  defp enqueue_check(hr) do
    %{"house_rule_id" => hr.id, "game_id" => hr.game_id}
    |> Workers.HouseRuleCheckWorker.new()
    |> Oban.insert()
  end
end
