defmodule RuleMaven.Readiness do
  @moduledoc """
  The end-to-end "get a game ready to play" pipeline, formalized.

  A game moves through an ordered ladder of steps. The first five are
  **required** and together define `games.playable` (the new, stronger
  definition of playable — RAG-ready *and* reviewed):

      source → extract → review → cleanup → embed   ▲ playable

  The rest are **enrichment** (cheat sheet, setup checklist, categories,
  "did you know?", voices, theme, BGG) — nice-to-have polish that does *not*
  gate playable.

  This module is the single source of truth for:

    * the step list and each step's completion signal (`state/1`),
    * the playable invariant (`recompute/1`, which stamps `games.playable`),
    * one-click automation (`start_auto/2` + `drive/1`), driven durably by the
      `ReadinessWorker` and advanced centrally from `Jobs.finish_run/3`.

  Automation is non-blocking and durable: each step is an existing Oban worker,
  and the *only* thing this layer adds is "what runs next" — recomputed from
  persisted state every time, so it survives a server restart mid-pipeline.
  Human-gated steps (review) pause the pipeline rather than spend LLM budget.
  """
  import Ecto.Query
  require Logger

  alias RuleMaven.{Audit, CheatSheet, Games, Repo, Settings, Voices}
  alias RuleMaven.Games.{Chunk, Document, Game}

  alias RuleMaven.Workers.{
    BggEnrichWorker,
    CategoriesWorker,
    CleanupWorker,
    CommonMistakesWorker,
    DidYouKnowWorker,
    FirstPlayerWorker,
    QuizWorker,
    ReadinessWorker,
    ScoreCategoriesWorker,
    SuggestionsWorker,
    SymbolKeyWorker,
    TeachPitchWorker,
    ThemePaletteWorker,
    TurnFlowWorker,
    VoiceSuggestionsWorker
  }

  @required ~w(bgg source extract review cleanup embed)a
  @enrichment ~w(theme suggestions categories cheat_sheet setup did_you_know voices first_player common_mistakes quiz teach score turn symbols)a

  # Steps that spend LLM/embedding budget — the ones we estimate + total cost for.
  @llm_steps ~w(extract cleanup embed suggestions categories cheat_sheet setup did_you_know voices theme first_player common_mistakes quiz teach score turn symbols)a

  @doc "Ordered required steps (the ones that gate `playable`)."
  def required_steps, do: @required
  @doc "Ordered enrichment steps (post-playable polish)."
  def enrichment_steps, do: @enrichment

  @doc """
  All steps, display order. `:theme` is pulled out of its normal enrichment
  slot and shown right after `:bgg` — it only needs the BGG cover image, so it
  can (and should) run before the rulebook pipeline even starts.
  """
  def all_steps, do: [:bgg, :theme] ++ (@required -- [:bgg]) ++ (@enrichment -- [:theme])

  @doc "PubSub topic a page subscribes to for live readiness updates."
  def topic(game_id), do: "readiness:#{game_id}"

  def category(step) when step in @required, do: :required
  def category(_step), do: :enrichment

  @doc "True when a step incurs LLM/embedding cost (drives cost estimate display)."
  def llm_step?(step), do: step in @llm_steps

  def label(:source), do: "Source uploaded"
  def label(:extract), do: "Text extracted"
  def label(:review), do: "Low-confidence pages reviewed"
  def label(:cleanup), do: "Cleaned up"
  def label(:embed), do: "Chunked & embedded"
  def label(:suggestions), do: "Suggested questions"
  def label(:categories), do: "Categories"
  def label(:cheat_sheet), do: "Cheat sheet"
  def label(:setup), do: "Setup checklist"
  def label(:did_you_know), do: "“Did you know?” facts"
  def label(:voices), do: "Personas"
  def label(:theme), do: "Theme palette"
  def label(:bgg), do: "BoardGameGeek data"
  def label(:first_player), do: "First-player picker"
  def label(:common_mistakes), do: "Common mistakes"
  def label(:quiz), do: "Rules quiz"
  def label(:teach), do: "60-second teach"
  def label(:score), do: "Score pad"
  def label(:turn), do: "Turn wizard"
  def label(:symbols), do: "Symbol key"

  ## State -------------------------------------------------------------------

  @doc """
  Full readiness snapshot for a game: an ordered list of
  `%{id, label, category, llm, state}` where `state` is
  `:done | :pending | :blocked`. `:blocked` marks a step whose prerequisites
  aren't met yet (so the UI can dim it).
  """
  def state(%Game{} = game), do: state(game, Games.list_documents(game))

  @doc """
  `state/1` for already-loaded documents (`Games.list_documents/1`), and
  optionally an already-computed `completion/2` map so callers that also need
  `required_complete?/1` or cost estimates check each step only once.
  """
  def state(game, docs, done \\ nil)
  def state(%Game{} = game, docs, nil), do: state(game, docs, completion(game, docs))

  def state(%Game{} = _game, _docs, done) do
    # Enrichments read the embedded rulebook text, so every step after
    # "Chunked & embedded" stays blocked until embedding completes.
    embed_done = done[:embed]

    {steps, _prev_done} =
      Enum.map_reduce(all_steps(), true, fn step, prev_done ->
        complete = done[step]

        {%{
           id: step,
           label: label(step),
           category: category(step),
           llm: llm_step?(step),
           state: step_state(step, complete, prev_done, embed_done, done)
         }, prev_done and (complete or category(step) == :enrichment)}
      end)

    steps
  end

  defp step_state(step, complete, prev_done, embed_done, done) do
    cond do
      complete -> :done
      category(step) == :required and not prev_done -> :blocked
      # Theme only needs the BGG cover image, not the embedded rulebook —
      # gate it on :bgg instead of the shared embed_done gate so it can run
      # (and show as runnable) well before the rest of the pipeline.
      step == :theme -> if done[:bgg], do: :pending, else: :blocked
      category(step) == :enrichment and not embed_done -> :blocked
      true -> :pending
    end
  end

  @doc """
  `%{step => complete?}` for every step in `all_steps/0`, each checked once
  against the given documents (one load shared by every step).
  """
  def completion(%Game{} = game, docs) do
    Map.new(all_steps(), &{&1, step_complete?(&1, game, docs)})
  end

  @doc "True when every required step is complete (ignores the publish gate)."
  def required_complete?(%Game{} = game), do: required_complete?(game, Games.list_documents(game))

  @doc "`required_complete?/1` for loaded documents or a `completion/2` map."
  def required_complete?(%Game{} = _game, %{} = done), do: Enum.all?(@required, &done[&1])

  def required_complete?(%Game{} = game, docs) when is_list(docs),
    do: Enum.all?(@required, &step_complete?(&1, game, docs))

  @doc "True when the game is live: required steps complete AND publish approved."
  def playable?(%Game{} = game), do: required_complete?(game) and publish_approved?(game.id)

  @doc """
  Recompute the playable invariant and persist it onto the game (only writing
  when it actually changed), then broadcast so any open page refreshes.
  Returns the boolean.
  """
  def recompute(game, docs \\ nil)

  def recompute(%Game{} = game, docs) do
    docs = docs || Games.list_documents(game)
    # A game goes playable only when every required step is complete AND an admin
    # has manually approved publishing it — the gate keeps a fully-prepared game
    # from auto-going-live before someone is ready.
    now = required_complete?(game, docs) and publish_approved?(game.id)

    if now != game.playable do
      game
      |> Ecto.Changeset.change(
        playable: now,
        playable_at: if(now, do: DateTime.utc_now() |> DateTime.truncate(:second), else: nil)
      )
      |> Repo.update()
    end

    broadcast(game.id)
    now
  end

  def recompute(game_id, _docs) when is_integer(game_id) do
    case Repo.get(Game, game_id) do
      %Game{} = g -> recompute(g)
      _ -> false
    end
  end

  # --- per-step completion signals ---

  @doc false
  def step_complete?(:source, _game, docs), do: docs != []

  def step_complete?(:extract, _game, docs) do
    docs != [] and Enum.all?(docs, &doc_extracted?/1)
  end

  # Review is only meaningfully "done" once there's extracted text to review.
  # Without the doc_extracted? guard an unextracted source (no pages, so zero
  # low-confidence pages) reads as vacuously reviewed right after upload.
  # Gated on *extraction* confidence only (review_block_count/1): cleanup-critic
  # defects are produced by the cleanup step that runs after this one, so letting
  # them count re-closed this gate behind itself and deadlocked the pipeline.
  def step_complete?(:review, _game, docs) do
    docs != [] and
      Enum.all?(docs, &(doc_extracted?(&1) and Games.review_block_count(&1) == 0))
  end

  def step_complete?(:cleanup, _game, docs) do
    docs != [] and Enum.all?(docs, &doc_cleaned?/1)
  end

  # Embedding must chunk the *cleaned* text, so it can't count as done while
  # cleanup is still pending — even if (stale, raw-text) embedded chunks exist.
  def step_complete?(:embed, _game, docs) do
    docs != [] and Enum.all?(docs, &doc_cleaned?/1) and
      MapSet.subset?(MapSet.new(docs, & &1.id), embedded_doc_ids(docs))
  end

  # Done when categories exist as either an unsaved draft (Settings cache) or a
  # curated set in the table. First-time generation auto-saves straight to the
  # table and deletes the draft, so checking the cache alone would wrongly leave
  # this step pending after a successful generate.
  def step_complete?(:suggestions, %Game{id: id}, _docs), do: present?("suggestions_#{id}")

  def step_complete?(:categories, %Game{} = game, _docs),
    do: present?("categories_#{game.id}") or Games.list_game_categories(game) != []

  def step_complete?(:cheat_sheet, %Game{id: id}, _docs),
    do: Settings.get("cheat_status_#{id}") == "done"

  def step_complete?(:setup, %Game{id: id}, _docs),
    do: Settings.get("setup_status_#{id}") == "done"

  def step_complete?(:did_you_know, %Game{id: id}, _docs), do: present?("did_you_know_#{id}")
  def step_complete?(:first_player, %Game{id: id}, _docs), do: present?("first_player_#{id}")
  def step_complete?(:symbols, %Game{id: id}, _docs), do: RuleMaven.Symbols.done?(id)

  def step_complete?(:common_mistakes, %Game{id: id}, _docs),
    do: present?("common_mistakes_#{id}")

  def step_complete?(:quiz, %Game{id: id}, _docs), do: present?("quiz_#{id}")
  def step_complete?(:teach, %Game{id: id}, _docs), do: present?("teach_pitch_#{id}")
  def step_complete?(:score, %Game{id: id}, _docs), do: present?("score_categories_#{id}")
  def step_complete?(:turn, %Game{id: id}, _docs), do: present?("turn_flow_#{id}")
  def step_complete?(:voices, %Game{id: id}, _docs), do: Voices.game_voice_defs(id) != []
  # Expansions never generate their own palette — they inherit the base game's
  # (see `Games.effective_theme_palette/1`), so there's nothing for this game's
  # pipeline to do and the step reads as already satisfied.
  def step_complete?(:theme, %Game{} = game, _docs),
    do: Games.expansion?(game.id) or not is_nil(game.theme_palette)

  def step_complete?(:bgg, %Game{} = game, _docs), do: not is_nil(game.bgg_data)

  defp doc_extracted?(%Document{pages: pages}) do
    pages != [] and Enum.all?(pages, &(is_binary(&1.text) and &1.text != ""))
  end

  defp doc_cleaned?(%Document{status: "cleaned"}), do: true
  defp doc_cleaned?(%Document{pages: []}), do: false

  # A page counts as clean when the cleanup layer exists OR the auto cleanup
  # would skip it (high-confidence vision/ensemble lane — raw text is already
  # model output and the worker deliberately leaves `cleaned` nil). Without the
  # skippable check, any doc with a skipped page held the cleanup step Pending
  # forever, which also blocked embed and playable.
  defp doc_cleaned?(%Document{pages: pages}) do
    Enum.all?(pages, fn page ->
      is_binary(page.cleaned) or
        CleanupWorker.skippable_page?(page, :auto, false)
    end)
  end

  defp doc_embedded?(%Document{} = doc), do: MapSet.member?(embedded_doc_ids([doc]), doc.id)

  @doc """
  Ids of the given documents that are fully embedded: at least one chunk and
  none still waiting for a vector. One query for all of them.
  """
  def embedded_doc_ids(docs) do
    ids = Enum.map(docs, & &1.id)

    Repo.all(
      from c in Chunk,
        where: c.document_id in ^ids,
        group_by: c.document_id,
        having: count(c.id) > 0 and count(c.id) == count(c.embedding),
        select: c.document_id
    )
    |> MapSet.new()
  end

  defp present?(key), do: is_binary(Settings.get(key)) and Settings.get(key) != ""

  ## Auto-pilot --------------------------------------------------------------

  defp auto_key(game_id), do: "readiness_auto_#{game_id}"
  defp pause_key(game_id), do: "readiness_pause_#{game_id}"
  defp publish_key(game_id), do: "readiness_publish_#{game_id}"

  ## Manual publish gate -----------------------------------------------------

  @doc "True when an admin has approved publishing this game (the playable gate)."
  def publish_approved?(game_id), do: Settings.get(publish_key(game_id)) == "on"

  @doc "Approve publishing, then recompute so the game goes playable if ready. Audited."
  def approve_publish(%Game{} = game, actor \\ nil) do
    Settings.put(publish_key(game.id), "on")
    Audit.log(actor, "readiness.publish_approve", metadata: %{game_id: game.id})
    recompute(game)
  end

  @doc "Revoke publish approval; the game immediately drops out of playable. Audited."
  def revoke_publish(%Game{} = game, actor \\ nil) do
    Settings.put(publish_key(game.id), "off")
    Audit.log(actor, "readiness.publish_revoke", metadata: %{game_id: game.id})
    recompute(game)
  end

  @doc "True when one-click prepare is armed for this game."
  def auto?(game_id), do: Settings.get(auto_key(game_id)) == "on"

  @doc "Reason the auto pipeline is currently paused (`nil` when not paused)."
  def pause_reason(game_id), do: Settings.get(pause_key(game_id))

  @doc """
  Arm one-click prepare: persist the auto flag, audit who started it, and kick
  the `ReadinessWorker`. Idempotent — re-arming a running pipeline is a no-op
  beyond clearing any stale pause.
  """
  def start_auto(%Game{} = game, actor \\ nil) do
    Settings.put(auto_key(game.id), "on")
    Settings.put(pause_key(game.id), "")
    Audit.log(actor, "readiness.prepare", metadata: %{game_id: game.id})

    unless testing?() do
      %{"game_id" => game.id}
      |> ReadinessWorker.new()
      |> Oban.insert()
    end

    broadcast(game.id)
    :ok
  end

  @doc "Disarm one-click prepare."
  def stop_auto(game_id) do
    Settings.put(auto_key(game_id), "off")
    broadcast(game_id)
    :ok
  end

  @doc """
  Central advancement entry point, called from `Jobs.finish_run/3` when a
  pipeline step finishes. Enqueues the worker (cheap — the worker recomputes
  everything) only while auto is armed.
  """
  def advance(game_id) when is_integer(game_id) do
    if auto?(game_id) and not testing?() do
      %{"game_id" => game_id}
      |> ReadinessWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  @doc """
  Decide what the auto pipeline should do next, without doing it: `{:run, step}`
  (a required step to kick), `{:pause, reason}` (needs a human or a missing
  prerequisite), or `:done` (every required step complete). Side-effect free, so
  callers (e.g. the prepare page's Run remaining) can report a blocker up front
  instead of arming a pipeline that would instantly re-pause.
  """
  def next_action(%Game{} = game), do: next_action(game, Games.list_documents(game))

  def next_action(%Game{} = game, docs) do
    cond do
      # BGG data is the first required step — it must be pulled before anything
      # else runs. Without a bgg_id there's nothing to pull, so pause for a human
      # to set one (or override) rather than silently stalling forever.
      not step_complete?(:bgg, game, docs) ->
        if is_nil(game.bgg_id), do: {:pause, "needs_bgg"}, else: {:run, :bgg}

      docs == [] ->
        {:pause, "needs_source"}

      not step_complete?(:extract, game, docs) ->
        {:run, :extract}

      not step_complete?(:review, game, docs) ->
        {:pause, "needs_review"}

      not step_complete?(:cleanup, game, docs) ->
        {:run, :cleanup}

      not step_complete?(:embed, game, docs) ->
        {:run, :embed}

      true ->
        :done
    end
  end

  @doc """
  Decide and launch the next action for a game's auto pipeline. Returns
  `{:running, step}` (a step was kicked), `{:paused, reason}` (needs a human or
  a missing prerequisite), or `:done` (playable reached + enrichments kicked;
  auto disarmed). Pure-ish: safe to call repeatedly; guards prevent
  double-enqueue.
  """
  def drive(%Game{} = game) do
    docs = Games.list_documents(game)

    case next_action(game, docs) do
      {:pause, reason} ->
        pause(game, reason)

      {:run, step} ->
        run_step(step, game, docs)
        clear_pause(game)
        {:running, step}

      :done ->
        # Required phase complete → game is playable. Kick the enrichment
        # fan-out once and consider auto satisfied (enrichments finish on their
        # own; we don't keep the pipeline armed waiting on optional polish).
        recompute(game)
        ensure_enrichments(game)
        Settings.put(auto_key(game.id), "off")
        clear_pause(game)
        :done
    end
  end

  defp run_step(:bgg, game, _docs), do: run_bgg(game)
  defp run_step(:extract, _game, docs), do: run_extract(docs)
  defp run_step(:cleanup, _game, docs), do: run_cleanup(docs)
  defp run_step(:embed, _game, docs), do: run_embed(docs)

  # Kick extraction for each source that isn't extracted yet and isn't already
  # being extracted. A failed/blank extract leaves the doc unextracted, so the
  # next advance (or the prepare page's Extract button) retries it.
  defp run_extract(docs) do
    Enum.each(docs, fn doc ->
      unless doc_extracted?(doc) or Games.extract_running?(doc.id) do
        Games.enqueue_extract(doc)
      end
    end)
  end

  # Pull BoardGameGeek data. The worker is `unique` per game, so the guard just
  # avoids a redundant enqueue while a pull is already in flight.
  defp run_bgg(%Game{} = game) do
    if Application.get_env(:rule_maven, Oban)[:testing] != :manual and
         game.id not in BggEnrichWorker.running_game_ids() do
      %{game_id: game.id} |> BggEnrichWorker.new() |> Oban.insert()
    end

    :ok
  end

  defp run_cleanup(docs) do
    Enum.each(docs, fn doc ->
      unless doc_cleaned?(doc) or Games.cleanup_running?(doc.id) do
        Games.enqueue_cleanup(doc, :auto)
      end
    end)
  end

  # Re-chunk from the cleaned text and let chunking enqueue embedding. Guard
  # against re-chunking a doc whose embed is already in flight (chunks exist but
  # some still lack a vector).
  defp run_embed(docs) do
    Enum.each(docs, fn doc ->
      unless doc_embedded?(doc) or embed_in_flight?(doc) do
        Games.chunk_document(doc)
      end
    end)
  end

  defp embed_in_flight?(%Document{id: doc_id}) do
    Repo.exists?(from c in Chunk, where: c.document_id == ^doc_id and is_nil(c.embedding))
  end

  # Fire whichever enrichment steps aren't done yet. Gated per-step on
  # step_complete?/3 (not a single "fired once ever" flag) so a step that
  # errored, or never actually finished, gets retried the next time this runs
  # instead of being silently skipped forever. The individual workers are
  # `unique` per game (and no-op in test), so calling this repeatedly is
  # safe-by-design — it only ever enqueues what's still outstanding.
  @doc false
  def ensure_enrichments(%Game{} = game) do
    for {step, enqueue} <- enrichment_enqueuers(), not step_complete?(step, game, []) do
      enqueue.(game)
    end

    # Expansions additionally get a "what this expansion changes" delta,
    # composed into their base games' setup checklist + cheat sheet. Not a
    # tracked readiness step, so fire it once (own Settings guard) rather than
    # on every call — its generate_async isn't safe to re-fire on a timer.
    safe(fn ->
      if Games.expansion?(game.id) and is_nil(RuleMaven.ExpansionDelta.status(game.id)) do
        RuleMaven.ExpansionDelta.generate_async(game)
      end
    end)

    :ok
  end

  # Each tracked enrichment step and how to (re)start it, in firing order.
  defp enrichment_enqueuers do
    [
      suggestions: &SuggestionsWorker.enqueue(&1.id),
      categories: &CategoriesWorker.enqueue(&1.id),
      did_you_know: &DidYouKnowWorker.enqueue(&1.id),
      voices: &VoiceSuggestionsWorker.enqueue(&1.id),
      first_player: &FirstPlayerWorker.enqueue(&1.id),
      symbols: &SymbolKeyWorker.enqueue(&1.id),
      common_mistakes: &CommonMistakesWorker.enqueue(&1.id),
      quiz: &QuizWorker.enqueue(&1.id),
      teach: &TeachPitchWorker.enqueue(&1.id),
      score: &ScoreCategoriesWorker.enqueue(&1.id),
      turn: &TurnFlowWorker.enqueue(&1.id),
      setup: fn game -> safe(fn -> RuleMaven.Setup.generate_async(game) end) end,
      cheat_sheet: fn game -> safe(fn -> CheatSheet.generate_async(game) end) end,
      # Theme is normally kicked off much earlier, right when BGG data lands
      # (see `BggEnrichWorker`) — this is just a safety net for the rare case
      # where that didn't happen (e.g. a game whose bgg_id was added after the
      # BGG step already ran).
      theme: fn game -> safe(fn -> ThemePaletteWorker.enqueue(game) end) end
    ]
  end

  defp pause(%Game{} = game, reason) do
    Settings.put(pause_key(game.id), reason)
    broadcast(game.id)
    {:paused, reason}
  end

  defp clear_pause(%Game{} = game), do: Settings.put(pause_key(game.id), "")

  defp broadcast(game_id) do
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:readiness, game_id})
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> Logger.debug("readiness enrichment kick failed: #{inspect(e)}")
  end

  defp testing?, do: Application.get_env(:rule_maven, Oban)[:testing] == :manual
end
