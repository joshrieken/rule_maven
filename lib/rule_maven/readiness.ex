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

  alias RuleMaven.{Repo, Settings, Games, Voices, Audit, CheatSheet}
  alias RuleMaven.Games.{Game, Document, Chunk}

  @required ~w(bgg source extract review cleanup embed)a
  @enrichment ~w(theme suggestions categories cheat_sheet setup did_you_know voices)a

  # Steps that spend LLM/embedding budget — the ones we estimate + total cost for.
  @llm_steps ~w(extract cleanup embed suggestions categories cheat_sheet setup did_you_know voices theme)a

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

  ## State -------------------------------------------------------------------

  @doc """
  Full readiness snapshot for a game: an ordered list of
  `%{id, label, category, llm, state}` where `state` is
  `:done | :pending | :blocked`. `:blocked` marks a step whose prerequisites
  aren't met yet (so the UI can dim it).
  """
  def state(%Game{} = game) do
    docs = Games.list_documents(game)
    # Enrichments read the embedded rulebook text, so every step after
    # "Chunked & embedded" stays blocked until embedding completes.
    embed_done = step_complete?(:embed, game, docs)

    {steps, _prev_done} =
      Enum.map_reduce(all_steps(), true, fn step, prev_done ->
        done = step_complete?(step, game, docs)

        s =
          cond do
            done -> :done
            category(step) == :required and not prev_done -> :blocked
            # Theme only needs the BGG cover image, not the embedded rulebook —
            # gate it on :bgg instead of the shared embed_done gate so it can run
            # (and show as runnable) well before the rest of the pipeline.
            step == :theme -> if step_complete?(:bgg, game, docs), do: :pending, else: :blocked
            category(step) == :enrichment and not embed_done -> :blocked
            true -> :pending
          end

        {%{
           id: step,
           label: label(step),
           category: category(step),
           llm: llm_step?(step),
           state: s
         }, prev_done and (done or category(step) == :enrichment)}
      end)

    steps
  end

  @doc "True when every required step is complete (ignores the publish gate)."
  def required_complete?(%Game{} = game) do
    docs = Games.list_documents(game)
    Enum.all?(@required, &step_complete?(&1, game, docs))
  end

  @doc "True when the game is live: required steps complete AND publish approved."
  def playable?(%Game{} = game), do: required_complete?(game) and publish_approved?(game.id)

  @doc """
  Recompute the playable invariant and persist it onto the game (only writing
  when it actually changed), then broadcast so any open page refreshes.
  Returns the boolean.
  """
  def recompute(%Game{} = game) do
    docs = Games.list_documents(game)
    # A game goes playable only when every required step is complete AND an admin
    # has manually approved publishing it — the gate keeps a fully-prepared game
    # from auto-going-live before someone is ready.
    now = Enum.all?(@required, &step_complete?(&1, game, docs)) and publish_approved?(game.id)

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

  def recompute(game_id) when is_integer(game_id) do
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
  def step_complete?(:review, _game, docs) do
    docs != [] and
      Enum.all?(docs, &(doc_extracted?(&1) and Games.review_page_count(&1) == 0))
  end

  def step_complete?(:cleanup, _game, docs) do
    docs != [] and Enum.all?(docs, &doc_cleaned?/1)
  end

  # Embedding must chunk the *cleaned* text, so it can't count as done while
  # cleanup is still pending — even if (stale, raw-text) embedded chunks exist.
  def step_complete?(:embed, _game, docs) do
    docs != [] and Enum.all?(docs, &(doc_cleaned?(&1) and doc_embedded?(&1)))
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
        RuleMaven.Workers.CleanupWorker.skippable_page?(page, :auto, false)
    end)
  end

  defp doc_embedded?(%Document{id: doc_id}) do
    total = Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc_id), :count)

    pending =
      Repo.aggregate(
        from(c in Chunk, where: c.document_id == ^doc_id and is_nil(c.embedding)),
        :count
      )

    total > 0 and pending == 0
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
      |> RuleMaven.Workers.ReadinessWorker.new()
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
      |> RuleMaven.Workers.ReadinessWorker.new()
      |> Oban.insert()
    end

    :ok
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

    cond do
      # BGG data is the first required step — it must be pulled before anything
      # else runs. Without a bgg_id there's nothing to pull, so pause for a human
      # to set one (or override) rather than silently stalling forever.
      not step_complete?(:bgg, game, docs) ->
        if is_nil(game.bgg_id) do
          pause(game, "needs_bgg")
        else
          run_bgg(game)
          clear_pause(game)
          {:running, :bgg}
        end

      docs == [] ->
        pause(game, "needs_source")

      not step_complete?(:extract, game, docs) ->
        run_extract(docs)
        clear_pause(game)
        {:running, :extract}

      not step_complete?(:review, game, docs) ->
        pause(game, "needs_review")

      not step_complete?(:cleanup, game, docs) ->
        run_cleanup(docs)
        clear_pause(game)
        {:running, :cleanup}

      not step_complete?(:embed, game, docs) ->
        run_embed(docs)
        clear_pause(game)
        {:running, :embed}

      true ->
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
         game.id not in RuleMaven.Workers.BggEnrichWorker.running_game_ids() do
      %{game_id: game.id} |> RuleMaven.Workers.BggEnrichWorker.new() |> Oban.insert()
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

  # Fire the enrichment fan-out exactly once per game (Settings guard). The
  # individual workers are `unique` per game and no-op in test, so this is
  # safe-by-design; the guard just avoids redundant enqueues on re-drive.
  @doc false
  def ensure_enrichments(%Game{} = game) do
    key = "readiness_enrich_#{game.id}"

    unless Settings.get(key) == "on" do
      Settings.put(key, "on")
      Games.generate_all(game.id)
      safe(fn -> CheatSheet.generate_async(game) end)

      # Theme is normally kicked off much earlier, right when BGG data lands
      # (see `BggEnrichWorker`) — this is just a safety net for the rare case
      # where that didn't happen (e.g. a game whose bgg_id was added after the
      # BGG step already ran).
      safe(fn ->
        if is_nil(game.theme_palette), do: RuleMaven.Workers.ThemePaletteWorker.enqueue(game)
      end)

      # Expansions additionally get a "what this expansion changes" delta,
      # composed into their base games' setup checklist + cheat sheet.
      safe(fn ->
        if Games.expansion?(game.id), do: RuleMaven.ExpansionDelta.generate_async(game)
      end)
    end

    :ok
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
