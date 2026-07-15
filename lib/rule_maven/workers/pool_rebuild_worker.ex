defmodule RuleMaven.Workers.PoolRebuildWorker do
  @moduledoc """
  Refills the answer pool after `Games.invalidate_pool/1` empties it.

  `invalidate_pool/1` is correct and deliberately blunt: any content change to a
  game (document approved, rejected, deleted, re-chunked, cleaned, glyph-scrubbed)
  stales EVERY cached answer for that game, because an answer grounded in text
  that just changed may no longer be true. Under-invalidating would serve answers
  quoting rulebook text that no longer exists, so it stays as it is.

  What was missing is the other half. The design assumed stale rows "re-pool on
  the next ask against the new text" — but that means the pool is rebuilt one
  PAID user ask at a time, and only for questions someone happens to ask again.
  Measured: a cleanup run over two days staled 68 rows and none of them ever came
  back, leaving the pool hit rate at 4.8%. A pool hit is the only $0 answer in
  this system, so an empty pool is the single largest cost line there is.

  This worker re-asks the questions that were servable before the invalidation,
  against the new text, and lets the ordinary ask path re-pool whatever still
  earns it. Two things make that cheap rather than expensive:

    * it is a ONE-TIME batch per rulebook edit, replacing an unbounded stream of
      full-price user asks that would each have paid for the same rebuild; and
    * the re-asks run back-to-back on one game, which is the only condition in
      which Gemini's prompt cache actually holds — a rebuilt question costs about
      half what the same question costs dribbling in from a user hours later.

  It does not persist answers itself. It pre-logs a row and enqueues `AskWorker`,
  exactly as the LiveView does, so the grounding gate, the citation check,
  `mark_pooled/1` and `PublishCheckWorker` all apply unchanged. A rebuilt answer
  earns its place in the pool on the same terms as any other, or it doesn't.

  Rebuilt rows carry `user_id: nil`: they are asked by the system, on nobody's
  behalf. That is load-bearing in three places — they must not consume a user's
  quota, must not accrue to a user's trust score, and must not be mistaken for
  the asker's own row by the same-user cache tiers.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    # A cleanup pass re-chunks page by page and invalidates on each one. Without
    # this, preparing a 40-page rulebook would enqueue 40 identical rebuilds and
    # each would re-ask the whole question set. Collapse them into one.
    #
    # The debounce is what makes that safe rather than lossy: candidates are read
    # at PERFORM time, not enqueue time, so the single surviving job sees every
    # page the cleanup touched, not just the one that enqueued it.
    #
    # `:incomplete` covers `:executing` too, so an invalidation landing while a
    # rebuild is mid-flight is suppressed. That window is seconds wide (this
    # worker only enqueues; the asks themselves run afterwards as separate jobs),
    # and it self-heals — the next content change enqueues another rebuild. The
    # alternative, letting concurrent rebuilds pile up on one game, is the more
    # expensive failure: each one re-asks the whole question set.
    unique: [period: 900, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{Games, Jobs, Repo}

  # The invalidation usually arrives mid-pipeline: chunking and embedding may
  # still be running behind it. Re-asking before the new chunks are embedded
  # would rebuild the pool against a half-written corpus and cache the result.
  # Wait for the dust to settle; the pool is already cold, a few minutes more
  # costs nothing.
  @default_delay_seconds 300

  # A ceiling on the spend a single rulebook edit can authorize. Rebuilds are
  # ordered most-recently-asked first, so the cap keeps the questions people
  # actually ask and drops the long tail.
  @default_max_questions 40

  @doc """
  Enqueues a debounced rebuild for `game_id`.

  Safe to call on every invalidation — the uniqueness window collapses a burst
  into one job.
  """
  def enqueue(game_id) when is_integer(game_id) do
    # Oban is not supervised in test, and `invalidate_pool/1` is reached from a
    # great many code paths that tests exercise. Same guard as
    # `PublishCheckWorker.enqueue/1`.
    if is_nil(Oban.Registry.whereis(Oban)) do
      :ok
    else
      %{game_id: game_id}
      |> new(schedule_in: delay_seconds())
      |> Oban.insert()
    end
  end

  def enqueue(_), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"game_id" => game_id}, id: oban_id}) do
    cond do
      not enabled?() ->
        :ok

      # Nothing to ground a rebuilt answer in. This is the common case during
      # first ingest: a game being prepared invalidates on every cleaned page
      # while it has no published document and no pooled answers yet.
      not Games.has_published_document?(game_id) ->
        :ok

      true ->
        rebuild(game_id, oban_id)
    end
  end

  def perform(_job), do: :ok

  defp rebuild(game_id, oban_id) do
    case candidates(game_id) do
      [] ->
        :ok

      rows ->
        game = Games.get_game!(game_id)

        run =
          Jobs.start_run(
            "pool_rebuild",
            {"game", game_id},
            "Pool rebuild — #{game.name}",
            oban_job_id: oban_id
          )

        Jobs.event(run, "info", "Re-asking #{length(rows)} staled question(s) against the new text.")

        enqueued = Enum.count(rows, &reask(&1, game_id))

        Jobs.finish_run(
          run,
          "done",
          "Queued #{enqueued}/#{length(rows)} question(s) for rebuild."
        )

        :ok
    end
  end

  # The rows worth rebuilding are the ones that were SERVABLE before the
  # invalidation — an answer that never cleared the citation gate is not made
  # correct by asking it again, and re-asking it would just re-buy a failure.
  #
  # `pooled` cannot be used to find them: `invalidate_pool/1` has already set it
  # false on every row, so the "was pooled" signal is gone by the time this runs.
  # `citation_valid and browsable` is the same predicate that pooling itself
  # tests, evaluated against what survived.
  defp candidates(game_id) do
    Repo.all(
      from(q in QuestionLog,
        where: q.game_id == ^game_id,
        where: q.stale == true,
        where: q.citation_valid == true,
        where: q.browsable == true,
        where: q.refused == false and q.blocked == false,
        where: is_nil(q.error_kind),
        # A pool-hit row is a COPY of an answer that some other row owns. Rebuild
        # the original; rebuilding the copies would re-ask the same question once
        # per person who ever received it.
        where: is_nil(q.pool_source_id),
        # A crew row is private to its crew and is served from the crew branch of
        # `find_pool_candidates/3`, which never requires `pooled`. It has no place
        # in the cross-user pool and must not be rebuilt into one.
        where: is_nil(q.group_id),
        # Community rows are curated. `invalidate_pool/1` sends them to a moderator
        # via `needs_review`; silently re-asking one would overwrite a human
        # decision with a machine's.
        where: not q.promoted,
        # `skip_normalize` ("Ask exactly this") rows have no `cleaned_question`,
        # never publish and never pool — there is nothing to rebuild.
        where: not is_nil(q.cleaned_question) and q.cleaned_question != "",
        order_by: [desc: q.inserted_at],
        select: %{
          cleaned_question: q.cleaned_question,
          expansion_ids: q.expansion_ids,
          question_embedding: q.question_embedding
        }
      )
    )
    |> Enum.uniq_by(&{&1.cleaned_question, Enum.sort(&1.expansion_ids || [])})
    |> Enum.reject(&already_live?(game_id, &1))
    |> Enum.take(max_questions())
  end

  # A question already answered and pooled — because a user re-asked it, or
  # because an earlier rebuild did — must not be paid for again.
  #
  # Matched by EMBEDDING, not by `cleaned_question` equality. String equality was
  # a real cost bug: a rebuilt row is normalized afresh, so its canonical text
  # routinely differs from the text on the stale row that seeded it ("What causes
  # Terror Level increase?" vs "What causes the Terror Level to increase?"). The
  # rebuild then failed to recognise its OWN output as live and re-asked all 47
  # questions on the next rulebook edit — the exact waste this worker exists to
  # remove. Caught by re-running a rebuild and asserting it queues nothing.
  # ...and by an embedding that has been checked for the tokens it cannot see. A
  # stale "Can a player trade AFTER rolling?" sits 0.93 from the pooled "Can a
  # player trade BEFORE rolling?" — inside the pool's own threshold — so a bare
  # distance test declares it already answered and drops it from this rebuild and
  # from every rebuild after, leaving a question permanently unanswerable from the
  # pool. Near enough to SERVE and asks the SAME THING are different questions.
  defp already_live?(game_id, %{question_embedding: emb, expansion_ids: exp} = row) do
    text = row.cleaned_question

    game_id
    |> RuleMaven.Games.pooled_equivalents(emb, exp)
    |> Enum.any?(fn live ->
      live_text = live.canonical_question || live.cleaned_question || live.question
      RuleMaven.LLM.QuestionFacets.compatible?(text, live_text)
    end)
  end

  defp reask(%{cleaned_question: text, expansion_ids: exp}, game_id) do
    exp = Enum.sort(exp || [])

    # `log_question/1`, not `log_question_with_rate_limit/2`: there is no user to
    # rate-limit, and a rebuild is not somebody's quota to spend.
    case Games.log_question(%{
           game_id: game_id,
           question: text,
           answer: "Thinking...",
           user_id: nil,
           promoted: false,
           expansion_ids: exp
         }) do
      {:ok, ql} ->
        %{
          game_id: game_id,
          question_log_id: ql.id,
          question: text,
          expansion_ids: exp,
          recent_context: [],
          user_id: nil,
          group_id: nil
        }
        |> RuleMaven.Workers.AskWorker.new()
        |> Oban.insert()
        |> case do
          {:ok, _job} ->
            true

          # Same hazard as the LiveView enqueue path: the row is committed as
          # "Thinking...", so a failed enqueue strands it non-terminal forever.
          # Nothing will ever finish it, and it would sit in the browse surfaces
          # as a permanently pending question. Delete it — unlike a user's ask,
          # a rebuild has nobody to show an error to and nothing to retry from.
          {:error, _reason} ->
            Games.delete_question(ql)
            false
        end

      {:error, _changeset} ->
        false
    end
  end

  defp enabled? do
    RuleMaven.Settings.get("pool_rebuild_enabled") != "false"
  end

  defp max_questions do
    parse_int(RuleMaven.Settings.get("pool_rebuild_max_questions"), @default_max_questions)
  end

  defp delay_seconds do
    parse_int(RuleMaven.Settings.get("pool_rebuild_delay_seconds"), @default_delay_seconds)
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default
end
