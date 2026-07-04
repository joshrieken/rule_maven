defmodule RuleMavenWeb.GameLive.Prepare do
  use RuleMavenWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias RuleMaven.{
    Users,
    Games,
    Readiness,
    LLM,
    Jobs,
    Settings,
    Setup,
    CheatSheet,
    Voices,
    Repo,
    Workers
  }

  alias RuleMaven.Games.Chunk
  alias RuleMaven.Readiness.Estimator

  # Map a readiness step to the llm_logs operation name(s) whose logged spend
  # represents that step's actual cost. Steps absent here have no tracked spend.
  @step_operations %{
    extract: ["ocr_vision", "ocr_critic"],
    cleanup: ["cleanup"],
    embed: [],
    suggestions: ["suggest_questions"],
    categories: ["categories"],
    cheat_sheet: ["cheat_sheet"],
    setup: ["setup"],
    did_you_know: ["did_you_know"],
    voices: ["voice"],
    theme: ["theme_palette"]
  }

  # Enrichment steps that can be re-run in place from this page (each maps to a
  # durable Oban worker), and the subset whose cached output can be cleared.
  @regen_steps ~w(suggestions categories cheat_sheet setup did_you_know voices theme bgg)a
  @clear_steps ~w(suggestions cheat_sheet setup did_you_know theme)a

  # JobRun.kind → step id, so a game-scoped running run lights up its step's
  # "Running…" indicator while the worker is in flight.
  @kind_to_step %{
    "extract" => :extract,
    "suggestions" => :suggestions,
    "categories" => :categories,
    "cheat_sheet" => :cheat_sheet,
    "setup_checklist" => :setup,
    "did_you_know" => :did_you_know,
    "voices" => :voices,
    "theme_palette" => :theme,
    "bgg_enrich" => :bgg
  }

  # JobRun.kind → step id for the inline per-step job log. Superset of
  # @kind_to_step: includes the document-scoped kinds (cleanup/embed/reextract)
  # and the ingest download, which the game-scoped running indicator ignores.
  @run_kind_to_step %{
    "download" => :source,
    "extract" => :extract,
    "reextract" => :extract,
    "cleanup" => :cleanup,
    "embed" => :embed,
    "bgg_enrich" => :bgg,
    "suggestions" => :suggestions,
    "categories" => :categories,
    "cheat_sheet" => :cheat_sheet,
    "setup_checklist" => :setup,
    "did_you_know" => :did_you_know,
    "voices" => :voices,
    "theme_palette" => :theme
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Users.can?(socket.assigns.current_user, :admin) && Games.get_game_by_token(id)

    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(game) ->
        {:ok, socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      true ->
        Readiness.recompute(game)

        if connected?(socket) do
          Jobs.subscribe(Readiness.topic(game.id))
          Jobs.subscribe(Jobs.scope_topic("game", game.id))
          # Event lines only broadcast on the admin feed; the inline per-step
          # job log filters them to this game's runs in handle_info.
          Jobs.subscribe(Jobs.admin_topic())

          for d <- Games.list_documents(game) do
            Jobs.subscribe(Jobs.scope_topic("document", d.id))
          end
        end

        {:ok,
         socket
         |> assign(game: game, page_title: "Prepare — #{game.name}")
         |> load()}
    end
  end

  defp load(socket) do
    game = socket.assigns.game
    docs = Games.list_documents(game)
    steps = Readiness.state(game)
    # Scope the cost readout to spend since the last pipeline reset (nil = all
    # time) so a fresh reset shows $0.00 without deleting billing history.
    cost_since = Games.preparation_reset_at(game.id)
    by_operation = LLM.cost_by_operation_for_game(game.id, cost_since)

    estimates =
      Map.new(steps, fn s -> {s.id, Estimator.step_cost(s.id, game, docs)} end)

    actuals =
      Map.new(steps, fn s -> {s.id, step_actual_cost(s.id, by_operation)} end)

    review_pages = Enum.sum(Enum.map(docs, &Games.review_page_count/1))
    step_logs = load_step_logs(game, docs)

    step_run_ids =
      step_logs |> Map.values() |> Enum.flat_map(& &1.runs) |> MapSet.new(& &1.id)

    assign(socket,
      steps: steps,
      step_logs: step_logs,
      step_run_ids: step_run_ids,
      previews: build_previews(game, docs),
      running_steps: running_steps(game),
      playable?: Readiness.playable?(game),
      required_complete?: Readiness.required_complete?(game),
      publish_approved?: Readiness.publish_approved?(game.id),
      auto?: Readiness.auto?(game.id),
      pause_reason: Readiness.pause_reason(game.id),
      remaining_cost: Estimator.remaining_cost(game),
      rerun_cost: Estimator.rerun_cost(game),
      estimates: estimates,
      actuals: actuals,
      total_actual: LLM.cost_for_game(game.id, cost_since),
      required_done: Enum.count(steps, &(&1.category == :required and &1.state == :done)),
      required_total: length(Readiness.required_steps()),
      review_pages: review_pages,
      question_count: Games.question_count(game)
    )
  end

  @impl true
  def handle_event("prepare", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.start_auto(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Preparing — running the pipeline…")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  def handle_event("approve_publish", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.approve_publish(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Published — the game is now ready.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  def handle_event("revoke_publish", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Readiness.revoke_publish(socket.assigns.game, socket.assigns.current_user)

      {:noreply,
       socket
       |> load()
       |> put_flash(:info, "Unpublished — the game is no longer ready.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  # Wipe the whole pipeline back to a blank, pre-prepare state. Gated to admins
  # and to games with no logged questions (the UI also disables the button, but
  # re-check here — the client can't be trusted).
  def handle_event("reset_all", _params, socket) do
    game = socket.assigns.game

    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      true ->
        case Games.reset_preparation(game) do
          {:error, :has_questions} ->
            {:noreply,
             socket
             |> reload()
             |> put_flash(:error, "Can't reset — this game already has questions.")}

          :ok ->
            if socket.assigns.playable?,
              do: Readiness.revoke_publish(game, socket.assigns.current_user)

            Readiness.recompute(game)

            {:noreply,
             socket
             |> reload()
             |> put_flash(:info, "Reset — all rulebooks and generated content removed.")}
        end
    end
  end

  # Run text extraction on demand for every saved-but-unextracted source. Each
  # enqueues a durable ExtractWorker; progress streams over the document Jobs
  # topic (mount subscribes) and lights up the extract step's "Running…".
  def handle_event("extract", _params, socket) do
    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      step_blocked?(socket, :extract) ->
        {:noreply, blocked_flash(socket)}

      true ->
        docs = Games.list_documents(socket.assigns.game)

        pending =
          Enum.reject(docs, fn d ->
            Readiness.step_complete?(:extract, socket.assigns.game, [d]) or
              Games.extract_running?(d.id)
          end)

        Enum.each(pending, &Games.enqueue_extract/1)

        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Extracting the rulebook text — running in the background…")}
    end
  end

  # Clean the extracted text on demand for every source that's been extracted but
  # not yet cleaned. Each enqueues a durable CleanupWorker (strength :auto,
  # escalation loop); progress streams over the document Jobs topic.
  def handle_event("clean_all", _params, socket) do
    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      step_blocked?(socket, :cleanup) ->
        {:noreply, blocked_flash(socket)}

      true ->
        game = socket.assigns.game
        docs = Games.list_documents(game)

        pending =
          Enum.filter(docs, fn d ->
            Readiness.step_complete?(:extract, game, [d]) and
              not Readiness.step_complete?(:cleanup, game, [d]) and
              not Games.cleanup_running?(d.id)
          end)

        Enum.each(pending, &Games.enqueue_cleanup(&1, :auto))

        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Cleaning up the rulebook text — running in the background…")}
    end
  end

  # Chunk + embed on demand for every cleaned-but-unembedded source. Chunking
  # enqueues the durable EmbedChunksWorker; the nil-embedding chunk count drives
  # the "Embedding…" indicator until every vector lands.
  def handle_event("embed", _params, socket) do
    cond do
      not Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      step_blocked?(socket, :embed) ->
        {:noreply, blocked_flash(socket)}

      true ->
        game = socket.assigns.game
        docs = Games.list_documents(game)

        pending =
          Enum.filter(docs, fn d ->
            Readiness.step_complete?(:cleanup, game, [d]) and
              not Readiness.step_complete?(:embed, game, [d]) and
              not embed_in_flight?(d.id)
          end)

        Enum.each(pending, &Games.chunk_document/1)

        {:noreply,
         socket
         |> load()
         |> put_flash(
           :info,
           "Chunking and embedding the rulebook text — running in the background…"
         )}
    end
  end

  def handle_event("stop", _params, socket) do
    Readiness.stop_auto(socket.assigns.game.id)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, "Paused — the pipeline will stop after the current step.")}
  end

  # Re-run a single enrichment step. Each path enqueues a durable Oban worker and
  # returns immediately; progress streams back over the game's job topic (mount
  # subscribes), which reloads this page and lights up the step's "Running…".
  def handle_event("regen_step", %{"step" => step}, socket) do
    case admin_step(socket, step, @regen_steps) do
      nil ->
        {:noreply, socket}

      id ->
        # Blocked steps (enrichments before embedding is done) can't run — the UI
        # hides the button, but re-check here since the client can't be trusted.
        if step_blocked?(socket, id) do
          {:noreply, blocked_flash(socket)}
        else
          do_regen_step(id, socket)
        end
    end
  end

  def handle_event("clear_step", %{"step" => step}, socket) do
    case admin_step(socket, step, @clear_steps) do
      nil ->
        {:noreply, socket}

      id ->
        clear_step(id, socket.assigns.game)

        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Cleared “#{Readiness.label(id)}”.")}
    end
  end

  # Categories are the one enrichment with hand-editing beyond regen/clear:
  # commit a regenerated draft, delete a single category, or re-tag every
  # question against the current set. Regenerating an existing set leaves a draft
  # (see CategoriesWorker) rather than nuking the saved set, so "Save" commits it.
  def handle_event("save_categories", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      game = socket.assigns.game
      draft = category_draft(game.id)

      if draft != [] do
        Games.replace_game_categories(game, draft)
        Settings.delete("categories_#{game.id}")
      end

      {:noreply, socket |> reload() |> put_flash(:info, "Categories saved.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      Games.delete_game_category(String.to_integer(id))
      {:noreply, reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retag_categories", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      count = Games.retag_all_questions(socket.assigns.game)
      {:noreply, put_flash(socket, :info, "Re-tagging #{count} question(s) in the background.")}
    else
      {:noreply, socket}
    end
  end

  # Resolve the phx-value step name to a known step atom, but only if the user is
  # an admin and the step is in the allowed set for the action. Flashes + returns
  # nil otherwise so the caller no-ops.
  defp admin_step(socket, step, allowed) do
    id = step_atom(step)

    cond do
      not Users.can?(socket.assigns.current_user, :admin) -> nil
      id in allowed -> id
      true -> nil
    end
  end

  defp step_atom(s) when is_binary(s), do: Enum.find(Readiness.all_steps(), &(to_string(&1) == s))
  defp step_atom(_), do: nil

  defp do_regen_step(id, socket) do
    regen_step(id, socket.assigns.game)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, "Re-running “#{Readiness.label(id)}” — running in the background…")}
  end

  defp step_blocked?(socket, id) do
    socket.assigns.game
    |> Readiness.state()
    |> Enum.any?(&(&1.id == id and &1.state == :blocked))
  end

  defp blocked_flash(socket) do
    put_flash(socket, :error, "That step is blocked — complete the earlier steps first.")
  end

  defp regen_step(:suggestions, g) do
    # Clear first so a failed/empty run doesn't leave stale questions on screen.
    Settings.delete("suggestions_#{g.id}")
    Workers.SuggestionsWorker.enqueue(g.id)
  end

  defp regen_step(:categories, g), do: Workers.CategoriesWorker.enqueue(g.id)
  defp regen_step(:cheat_sheet, g), do: CheatSheet.generate_async(g)
  defp regen_step(:setup, g), do: Setup.generate_async(g)

  defp regen_step(:did_you_know, g) do
    # Clear first so a failed/empty run doesn't leave stale facts on screen.
    Settings.delete("did_you_know_#{g.id}")
    Workers.DidYouKnowWorker.enqueue(g.id)
  end

  defp regen_step(:voices, g), do: Workers.VoiceSuggestionsWorker.enqueue(g.id)
  defp regen_step(:theme, g), do: Workers.ThemePaletteWorker.enqueue(g)
  defp regen_step(:bgg, g), do: %{game_id: g.id} |> Workers.BggEnrichWorker.new() |> Oban.insert()
  defp regen_step(_, _), do: :ok

  defp clear_step(:suggestions, g), do: Settings.delete("suggestions_#{g.id}")
  defp clear_step(:cheat_sheet, g), do: CheatSheet.clear(g.id)
  defp clear_step(:setup, g), do: Setup.clear(g.id)
  defp clear_step(:did_you_know, g), do: Settings.delete("did_you_know_#{g.id}")
  defp clear_step(:theme, g), do: Games.update_game(g, %{theme_palette: nil})
  defp clear_step(_, _), do: :ok

  # True when any of the game's sources has a cleanup job queued/running. Cleanup
  # is document-scoped, so it isn't covered by `running_steps/1`.
  defp cleanup_active?(game) do
    game |> Games.list_documents() |> Enum.any?(&Games.cleanup_running?(&1.id))
  end

  # Embedding in flight = chunks exist that still lack a vector (the
  # EmbedChunksWorker fills them in). Document-scoped like cleanup, so it isn't
  # covered by `running_steps/1` either.
  defp embed_in_flight?(doc_id) do
    Repo.exists?(from(c in Chunk, where: c.document_id == ^doc_id and is_nil(c.embedding)))
  end

  defp embed_active?(game) do
    game |> Games.list_documents() |> Enum.any?(&embed_in_flight?(&1.id))
  end

  # Latest runs per step (newest first, capped at 3) plus the newest run's
  # event lines, feeding each step's inline job log. Two run queries (game +
  # per-doc scope) and one events query per step that has runs — the page is
  # admin-only and reloads on job traffic, so eager loading is fine.
  defp load_step_logs(game, docs) do
    game_runs = Jobs.list_runs(scope_type: "game", scope_id: game.id, limit: 200)

    doc_runs =
      Enum.flat_map(docs, &Jobs.list_runs(scope_type: "document", scope_id: &1.id, limit: 100))

    (game_runs ++ doc_runs)
    |> Enum.group_by(&Map.get(@run_kind_to_step, &1.kind))
    |> Map.delete(nil)
    |> Map.new(fn {step, runs} ->
      [latest | _] = runs = runs |> Enum.sort_by(& &1.id, :desc) |> Enum.take(3)
      # Newest line first (Jobs.events order) — latest progress stays visible
      # at the top of the box without scrolling.
      {step, %{runs: runs, events: Jobs.events(latest.id, 40)}}
    end)
  end

  # Steps with a game-scoped run currently in flight (drives the "Running…" tag).
  defp running_steps(game) do
    [state: "running", scope_type: "game", scope_id: game.id, limit: 100]
    |> Jobs.list_runs()
    |> Enum.flat_map(fn run ->
      case Map.get(@kind_to_step, run.kind) do
        nil -> []
        id -> [id]
      end
    end)
    |> MapSet.new()
  end

  @impl true
  def handle_info({:readiness, _game_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:job_run, _run}, socket), do: {:noreply, reload(socket)}

  # Admin-feed event lines: refresh only when the line belongs to one of the
  # runs shown in this page's per-step logs (the feed carries every run app-wide).
  def handle_info({:job_event, %{job_run_id: rid}}, socket) do
    if MapSet.member?(socket.assigns.step_run_ids, rid) do
      {:noreply, reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket) do
    game = Games.get_game!(socket.assigns.game.id)

    socket
    |> assign(game: game)
    |> load()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/games/#{@game}/edit"} class="back-link">
        &larr; Back to {String.slice(@game.name, 0, 30)}
      </.link>

      <div style="display:flex;align-items:center;justify-content:space-between;gap:1rem;margin:0.25rem 0 0.35rem">
        <div style="display:flex;align-items:center;gap:0.75rem">
          <img
            :if={@game.image_url}
            src={@game.image_url}
            alt={@game.name}
            style="width:3.5rem;height:3.5rem;object-fit:cover;border-radius:0.5rem;box-shadow:0 2px 8px rgba(0,0,0,0.18);flex-shrink:0"
          />
          <h1 style="font-size:1.5rem;font-weight:700">Prepare {@game.name}</h1>
        </div>
      </div>
      <p style="font-size:0.85rem;font-weight:600;margin:0 0 1rem;color:var(--text-muted)">
        <%= cond do %>
          <% @playable? -> %>
            <span style="color:var(--green)">✓ Ready</span>
          <% @required_complete? -> %>
            <span style="color:var(--yellow)">● Ready to publish — awaiting your approval</span>
          <% true -> %>
            Setting up… {@required_done}/{@required_total} required steps
        <% end %>
      </p>

      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(9rem,1fr));gap:0.6rem;margin-bottom:1rem">
        <.stat label="Remaining est. cost" value={"$#{fmt_cost(@remaining_cost)}"} />
        <.stat label="Actual cost so far" value={"$#{fmt_cost(@total_actual)}"} />
        <.stat label="Ready" value={if @playable?, do: "Yes", else: "No"} />
      </div>

      <div style="display:flex;align-items:center;gap:0.75rem;margin-bottom:1rem">
        <%= if @auto? do %>
          <span style="display:inline-flex;align-items:center;gap:0.4rem;font-size:0.85rem;font-weight:600;color:var(--accent)">
            <span style="display:inline-block;width:0.55rem;height:0.55rem;border-radius:50%;background:var(--accent)"></span>
            Running…
          </span>
          <button
            phx-click="stop"
            style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.4rem 1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:pointer"
          >
            Pause
          </button>
        <% else %>
          <%!-- Once the game is Ready, re-running the pipeline re-spends on
                enrichments, so deemphasize the action and confirm-gate it. --%>
          <button
            phx-click="prepare"
            data-confirm={
              @playable? &&
                "This game is already Ready. Re-run the pipeline (regenerates enrichments and spends)?"
            }
            style={
              if @playable?,
                do:
                  "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:pointer",
                else:
                  "background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:700;cursor:pointer"
            }
          >
            {if @playable?, do: "Re-run prepare", else: "Prepare game"} · est. ${fmt_cost(
              if @playable?, do: @rerun_cost, else: @remaining_cost
            )}
          </button>
        <% end %>

        <%!-- Manual publish gate: a fully-prepared game stays unpublished until
              an admin approves it here. Shown greyed out (with the remaining
              required steps in the tooltip) until every required step is done. --%>
        <button
          :if={@required_complete? && !@playable?}
          phx-click="approve_publish"
          style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:700;cursor:pointer"
        >
          ✓ Mark Ready
        </button>
        <button
          :if={!@required_complete? && !@playable?}
          disabled
          title={"Remaining before publish: #{remaining_required_labels(@steps)}"}
          style="background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:700;cursor:not-allowed"
        >
          ✓ Mark Ready
        </button>
        <button
          :if={@playable?}
          phx-click="revoke_publish"
          data-confirm="Unpublish this game? Users won't be able to ask questions until you re-publish."
          style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.85rem;font-weight:600;cursor:pointer"
        >
          Unpublish
        </button>

        <%!-- Danger zone: wipe the whole pipeline. Only offered while no questions
              have been logged — once players have engaged, show it disabled with a
              reason instead. Right-aligned so it reads apart from the build actions. --%>
        <%= if @question_count == 0 do %>
          <button
            phx-click="reset_all"
            data-confirm={"Delete every rulebook and all generated content for “#{@game.name}”? This can’t be undone."}
            style="margin-left:auto;background:var(--bg-subtle);color:var(--red);border:1px solid color-mix(in srgb,var(--red) 40%,var(--border));padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:pointer"
          >
            Reset all
          </button>
        <% else %>
          <span
            title="Reset is disabled because this game already has logged questions."
            style="margin-left:auto;display:inline-flex;align-items:center;gap:0.5rem"
          >
            <button
              disabled
              style="background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border);padding:0.45rem 1.1rem;border-radius:0.375rem;font-size:0.82rem;font-weight:600;cursor:not-allowed;opacity:0.7"
            >
              Reset all
            </button>
            <span style="font-size:0.72rem;color:var(--text-muted);max-width:12rem;line-height:1.3">
              Players have asked questions — unpublish instead of resetting.
            </span>
          </span>
        <% end %>
      </div>

      <%= if @pause_reason && @pause_reason != "" do %>
        <div style="background:color-mix(in srgb,var(--yellow) 12%,var(--bg-surface));border:1px solid color-mix(in srgb,var(--yellow) 40%,var(--border));border-radius:0.5rem;padding:0.7rem 0.9rem;margin-bottom:1.25rem;font-size:0.82rem;color:var(--text)">
          {pause_message(assigns)}
        </div>
      <% end %>

      <style>
        [data-prepare-body]{display:none}
        [data-prepare-step][data-open] [data-prepare-body]{display:block}
        [data-prepare-caret]{display:inline-block;transition:transform .12s}
        [data-prepare-step][data-open] [data-prepare-caret]{transform:rotate(90deg)}
      </style>

      <div id="pipeline" phx-hook="PrepareCollapse" data-game={@game.id}>
        <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;margin:0 0 0.5rem">
          <h2 style="font-size:1rem;font-weight:700">Pipeline</h2>
          <button
            type="button"
            data-prepare-all="expand"
            style="background:none;border:none;color:var(--accent);font-size:0.78rem;font-weight:600;cursor:pointer;padding:0"
          >
            Expand all
          </button>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.5rem;overflow:hidden">
          <%= for step <- @steps do %>
            <.step_row
              step={step}
              game={@game}
              preview={Map.get(@previews, step.id)}
              running={MapSet.member?(@running_steps, step.id)}
              estimate={Map.get(@estimates, step.id, 0.0)}
              actual={Map.get(@actuals, step.id)}
              action={step_action(step, @game)}
              log={Map.get(@step_logs, step.id)}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :game, :map, required: true
  attr :preview, :any, default: nil
  attr :running, :boolean, default: false
  attr :estimate, :float, required: true
  attr :actual, :any, required: true
  attr :action, :any, default: nil
  attr :log, :any, default: nil

  defp step_row(assigns) do
    # A row is collapsible when it has a result to preview *or* an action to
    # offer. The body is always in the DOM (hidden by CSS); the PrepareCollapse
    # hook toggles `data-open` per the per-game expanded set it keeps in
    # localStorage.
    assigns =
      assign(
        assigns,
        :has_body,
        present_preview?(assigns.preview) or step_actions?(assigns.step.id)
      )

    ~H"""
    <div
      data-prepare-step={@has_body && to_string(@step.id)}
      style={"border-top:1px solid var(--border-subtle);#{if @step.state == :blocked, do: "opacity:0.62", else: ""}"}
    >
      <div
        data-prepare-head={@has_body && true}
        style={"display:flex;align-items:center;gap:0.75rem;padding:0.6rem 0.9rem;#{if @has_body, do: "cursor:pointer", else: ""}"}
      >
        <span
          data-prepare-caret={@has_body && true}
          style={"width:0.7rem;font-size:0.7rem;color:var(--text-muted);#{unless @has_body, do: "visibility:hidden", else: ""}"}
        >
          &#9656;
        </span>
        <span style={"font-size:0.7rem;font-weight:700;padding:0.15rem 0.5rem;border-radius:1rem;white-space:nowrap;#{chip_style(@step.state)}"}>
          {chip_label(@step.state)}
        </span>
        <span style="flex:1;font-size:0.85rem;font-weight:600;color:var(--text)">
          {@step.label}
          <.link
            :if={@action}
            navigate={@action.href}
            style="font-size:0.72rem;font-weight:600;color:var(--accent);margin-left:0.4rem;white-space:nowrap"
          >
            {@action.label} &rarr;
          </.link>
        </span>
        <span style={"font-size:0.62rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;#{tag_style(@step.category)}"}>
          {if @step.category == :required, do: "Required", else: "Enrichment"}
        </span>
        <%= if @step.llm do %>
          <span style="font-size:0.72rem;color:var(--text-muted);min-width:5.5rem;text-align:right;white-space:nowrap">
            {est_label(@step, @estimate)}
          </span>
          <span style="font-size:0.72rem;font-weight:600;color:var(--text);min-width:4.5rem;text-align:right;white-space:nowrap">
            {cost_or_dash(@actual)}
          </span>
        <% else %>
          <span style="min-width:5.5rem"></span>
          <span style="min-width:4.5rem;text-align:right;font-size:0.72rem;color:var(--text-muted)">
            —
          </span>
        <% end %>
      </div>
      <div :if={@has_body} data-prepare-body style="padding:0 0.9rem 0.8rem 2.45rem">
        <.preview_body :if={present_preview?(@preview)} id={@step.id} preview={@preview} />
        <.step_actions step={@step} game={@game} running={@running} />
        <.step_log log={@log} />
      </div>
    </div>
    """
  end

  ## Step result previews ----------------------------------------------------

  # Gather every step's artifact up front (the page is admin-only and reloads on
  # each job event, so eager loading keeps the body markup self-contained). Steps
  # with no artifact map to a blank value and render no collapsible body.
  defp build_previews(game, docs) do
    %{
      source: docs,
      extract: doc_page_summary(docs, :text),
      cleanup: doc_page_summary(docs, :cleaned),
      review: review_summary(docs),
      embed: chunk_count(docs),
      suggestions: load_suggestions(game.id),
      categories: Games.list_game_categories(game),
      cheat_sheet: CheatSheet.stored_content(game.id),
      setup: Setup.stored_checklist(game.id),
      did_you_know: load_did_you_know(game.id),
      voices: Voices.game_voice_defs(game.id),
      theme: game.theme_palette,
      bgg: game.bgg_data
    }
  end

  defp doc_page_summary(docs, field) do
    Enum.map(docs, fn d ->
      %{
        label: d.label || "Untitled",
        done:
          Enum.count(d.pages, fn p -> is_binary(Map.get(p, field)) and Map.get(p, field) != "" end),
        total: length(d.pages)
      }
    end)
  end

  defp review_summary(docs) do
    Enum.map(docs, fn d ->
      %{label: d.label || "Untitled", remaining: Games.review_page_count(d)}
    end)
  end

  defp chunk_count([]), do: 0

  defp chunk_count(docs) do
    ids = Enum.map(docs, & &1.id)
    Repo.aggregate(from(c in Chunk, where: c.document_id in ^ids), :count)
  end

  # Suggested questions are stored as a JSON list of %{category, questions}.
  defp load_suggestions(game_id) do
    case Settings.get("suggestions_#{game_id}") do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) ->
            Enum.map(list, fn c ->
              %{category: c["category"], questions: c["questions"] || []}
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Unsaved category draft left by a regeneration over an existing set, as the
  # %{name, description} shape `replace_game_categories/2` expects.
  defp category_draft(game_id) do
    case Settings.get("categories_#{game_id}") do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) ->
            Enum.map(list, fn c -> %{name: c["name"], description: c["description"]} end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp load_did_you_know(game_id) do
    case Settings.get("did_you_know_#{game_id}") do
      nil ->
        []

      json ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
    end
  end

  defp present_preview?(nil), do: false
  defp present_preview?(n) when is_integer(n), do: n > 0
  defp present_preview?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_preview?(l) when is_list(l), do: l != []
  defp present_preview?(m) when is_map(m) and not is_struct(m), do: map_size(m) > 0
  defp present_preview?(_), do: false

  attr :id, :atom, required: true
  attr :preview, :any, required: true

  defp preview_body(assigns) do
    ~H"""
    <div style="font-size:0.8rem;color:var(--text-secondary);line-height:1.5">
      <%= case @id do %>
        <% :source -> %>
          <ul style="margin:0;padding-left:1.1rem">
            <li :for={d <- @preview}>
              {d.label || "Untitled"}
              <span style="color:var(--text-muted)">· {d.page_count || length(d.pages)} pages</span>
              <.link
                :if={is_binary(d.pdf_path)}
                href={~p"/rulebooks/#{RuleMaven.Hashid.encode(d.id)}/pdf"}
                target="_blank"
                style="margin-left:0.4rem;font-size:0.75rem"
              >View PDF</.link>
            </li>
          </ul>
        <% id when id in [:extract, :cleanup] -> %>
          <ul style="margin:0;padding-left:1.1rem">
            <li :for={d <- @preview}>{d.label} — {d.done}/{d.total} pages</li>
          </ul>
        <% :review -> %>
          <ul style="margin:0;padding-left:1.1rem">
            <li :for={d <- @preview}>
              {d.label} — {if d.remaining == 0, do: "all reviewed", else: "#{d.remaining} pending"}
            </li>
          </ul>
        <% :embed -> %>
          {fmt_int(@preview)} chunks embedded
        <% :suggestions -> %>
          <div :for={c <- @preview} style="margin-bottom:0.5rem">
            <div style="font-weight:700;font-size:0.66rem;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-muted);margin-bottom:0.15rem">
              {c.category}
            </div>
            <ul style="margin:0;padding-left:1.1rem">
              <li :for={q <- c.questions} style="margin-bottom:0.15rem">{q}</li>
            </ul>
          </div>
        <% :categories -> %>
          <div style="display:flex;flex-wrap:wrap;gap:0.3rem">
            <span
              :for={c <- @preview}
              title={c.description}
              style="display:inline-flex;align-items:center;gap:0.3rem;background:var(--bg-subtle);border:1px solid var(--border);border-radius:1rem;padding:0.1rem 0.3rem 0.1rem 0.55rem;font-size:0.72rem;font-weight:600"
            >
              {c.name}
              <button
                type="button"
                phx-click="delete_category"
                phx-value-id={c.id}
                data-confirm={"Delete the “#{c.name}” category?"}
                title="Delete category"
                style="display:inline-flex;align-items:center;justify-content:center;width:1rem;height:1rem;border:none;border-radius:50%;background:none;color:var(--text-muted);font-size:0.8rem;line-height:1;cursor:pointer"
              >
                ×
              </button>
            </span>
          </div>
        <% :cheat_sheet -> %>
          <div style="white-space:pre-wrap;max-height:16rem;overflow:auto;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.35rem;padding:0.5rem;font-size:0.74rem">
            {@preview}
          </div>
        <% :setup -> %>
          <div :if={@preview["components"] != []}>
            <div style="font-weight:700;font-size:0.7rem;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-muted);margin-bottom:0.2rem">
              Components
            </div>
            <ul style="margin:0 0 0.6rem;padding-left:1.1rem">
              <li :for={c <- @preview["components"]}>{c}</li>
            </ul>
          </div>
          <div :if={@preview["setup"] != []}>
            <div style="font-weight:700;font-size:0.7rem;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-muted);margin-bottom:0.2rem">
              Setup steps
            </div>
            <ol style="margin:0;padding-left:1.1rem">
              <li :for={s <- @preview["setup"]} style="margin-bottom:0.25rem">
                <span style="font-weight:600">{s["title"]}</span>
                <span
                  :if={s["detail"] not in [nil, "", "nil"]}
                  style="display:block;font-size:0.74rem;color:var(--text-muted)"
                >
                  {s["detail"]}
                </span>
              </li>
            </ol>
          </div>
        <% :did_you_know -> %>
          <ul style="margin:0;padding-left:1.1rem">
            <li :for={f <- @preview} style="margin-bottom:0.25rem">{to_string(f)}</li>
          </ul>
        <% :voices -> %>
          <div style="display:flex;flex-direction:column;gap:0.6rem">
            <div
              :for={v <- @preview}
              style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.4rem;padding:0.45rem 0.55rem"
            >
              <div style="display:flex;align-items:center;gap:0.35rem;font-size:0.8rem;font-weight:700">
                <span>{v.emoji}</span>{v.label}
              </div>
              <div
                :if={present_preview?(v[:style])}
                style="font-size:0.72rem;color:var(--text-muted);margin-top:0.15rem"
              >
                {v.style}
              </div>
              <%= if present_preview?(v[:loading_phrases]) do %>
                <div style="display:flex;flex-wrap:wrap;gap:0.25rem;margin-top:0.35rem">
                  <span
                    :for={p <- v.loading_phrases}
                    style="background:var(--bg-surface);border:1px solid var(--border);border-radius:1rem;padding:0.05rem 0.45rem;font-size:0.68rem;color:var(--text-secondary)"
                  >
                    {p}
                  </span>
                </div>
              <% else %>
                <div style="font-size:0.68rem;color:var(--text-muted);font-style:italic;margin-top:0.3rem">
                  No themed loading phrases yet — uses the generic pool. Re-run to generate.
                </div>
              <% end %>
            </div>
          </div>
        <% :theme -> %>
          <div style="display:flex;gap:0.75rem;flex-wrap:wrap">
            <%= for mode <- ["light", "dark"], is_map(@preview[mode]) do %>
              <% v = @preview[mode] %>
              <div style={"display:flex;align-items:center;gap:0.4rem;padding:0.4rem 0.5rem;border-radius:0.35rem;border:1px solid var(--border);background:#{v["--bg"]}"}>
                <span style={"font-size:0.62rem;font-weight:700;text-transform:capitalize;color:#{v["--text"]}"}>
                  {mode}
                </span>
                <span
                  :for={key <- ["--accent", "--bg", "--bg-surface", "--text"]}
                  title={key}
                  style={"width:0.9rem;height:0.9rem;border-radius:0.2rem;border:1px solid var(--border);background:#{v[key]}"}
                ></span>
              </div>
            <% end %>
          </div>
        <% :bgg -> %>
          <dl style="display:grid;grid-template-columns:auto 1fr;gap:0.15rem 0.6rem;margin:0">
            <%= for {k, val} <- bgg_rows(@preview) do %>
              <dt style="font-weight:600;color:var(--text-muted)">{k}</dt>
              <dd style="margin:0;overflow-wrap:anywhere">{val}</dd>
            <% end %>
          </dl>
        <% _ -> %>
          <span style="color:var(--text-muted)">No preview.</span>
      <% end %>
    </div>
    """
  end

  ## Step actions ------------------------------------------------------------

  # Every step has at least a manage/view link, so all steps offer an action and
  # get a collapsible body even before their artifact exists.
  defp step_actions?(_id), do: true

  attr :step, :map, required: true
  attr :game, :map, required: true
  attr :running, :boolean, default: false

  defp step_actions(assigns) do
    categories? = assigns.step.id == :categories

    assigns =
      assigns
      |> assign(:link, step_link(assigns.step.id, assigns.game))
      |> assign(:regen?, assigns.step.id in @regen_steps and assigns.step.state != :blocked)
      |> assign(:clear?, assigns.step.id in @clear_steps)
      |> assign(:done?, assigns.step.state == :done)
      |> assign(:extractable?, assigns.step.id == :extract and assigns.step.state == :pending)
      # Cleanup can run once extraction is done (state :pending, not :blocked) and
      # it isn't already cleaned. `cleaning?` reflects an in-flight run — cleanup
      # jobs are document-scoped, so they don't show up in the game-scoped
      # `running` MapSet and need their own check.
      |> assign(:cleanable?, assigns.step.id == :cleanup and assigns.step.state == :pending)
      |> assign(:cleaning?, assigns.step.id == :cleanup and cleanup_active?(assigns.game))
      # Embed can run once cleanup is done (state :pending, not :blocked). Like
      # cleanup it's document-scoped, so in-flight embedding needs its own check.
      |> assign(:embeddable?, assigns.step.id == :embed and assigns.step.state == :pending)
      |> assign(:embedding?, assigns.step.id == :embed and embed_active?(assigns.game))
      |> assign(:cat_draft?, categories? and category_draft(assigns.game.id) != [])
      |> assign(:cat_saved?, categories? and Games.list_game_categories(assigns.game) != [])

    ~H"""
    <div
      :if={
        @link || @regen? || @clear? || @cat_draft? || @cat_saved? || @extractable? || @cleanable? ||
          @embeddable?
      }
      style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap;margin-top:0.6rem"
    >
      <button
        :if={@extractable? && !@running}
        type="button"
        phx-click="extract"
        data-confirm="Extract the rulebook text now? This spends LLM budget."
        style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Extract
      </button>
      <button
        :if={@cleanable? && !@cleaning?}
        type="button"
        phx-click="clean_all"
        data-confirm="Clean up the extracted rulebook text now? This spends LLM budget."
        style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Clean up
      </button>
      <span
        :if={@cleaning?}
        style="display:inline-flex;align-items:center;gap:0.35rem;font-size:0.74rem;font-weight:600;color:var(--accent)"
      >
        <span style="display:inline-block;width:0.5rem;height:0.5rem;border-radius:50%;background:var(--accent)"></span>
        Cleaning…
      </span>
      <button
        :if={@embeddable? && !@embedding?}
        type="button"
        phx-click="embed"
        data-confirm="Chunk and embed the cleaned rulebook text now? This spends embedding budget."
        style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Chunk &amp; embed
      </button>
      <span
        :if={@embedding?}
        style="display:inline-flex;align-items:center;gap:0.35rem;font-size:0.74rem;font-weight:600;color:var(--accent)"
      >
        <span style="display:inline-block;width:0.5rem;height:0.5rem;border-radius:50%;background:var(--accent)"></span>
        Embedding…
      </span>
      <button
        :if={@cat_draft? && !@running}
        type="button"
        phx-click="save_categories"
        data-confirm="Save the regenerated categories? This replaces the current set and clears existing question tags."
        style="background:var(--blue);color:#fff;border:none;padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Save draft
      </button>
      <button
        :if={@cat_saved? && !@running}
        type="button"
        phx-click="retag_categories"
        data-confirm="Re-tag every existing question against the current categories?"
        style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Re-tag all
      </button>
      <span
        :if={@running}
        style="display:inline-flex;align-items:center;gap:0.35rem;font-size:0.74rem;font-weight:600;color:var(--accent)"
      >
        <span style="display:inline-block;width:0.5rem;height:0.5rem;border-radius:50%;background:var(--accent)"></span>
        Running…
      </span>
      <button
        :if={@regen? && !@running}
        type="button"
        phx-click="regen_step"
        phx-value-step={@step.id}
        data-confirm={regen_confirm(@step.id, @done?)}
        style="background:var(--accent);color:var(--accent-text,#fff);border:none;padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        {if @done?, do: "Regenerate", else: "Generate"}
      </button>
      <button
        :if={@clear? && !@running}
        type="button"
        phx-click="clear_step"
        phx-value-step={@step.id}
        data-confirm="Clear this result? It will need to be regenerated."
        style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.3rem 0.7rem;border-radius:0.3rem;font-size:0.74rem;font-weight:600;cursor:pointer"
      >
        Clear
      </button>
      <.link
        :if={@link}
        navigate={@link.href}
        style="font-size:0.74rem;font-weight:600;color:var(--accent);text-decoration:none"
      >
        {@link.label} &rarr;
      </.link>
    </div>
    """
  end

  # Confirm only actions that spend LLM budget or destroy an existing result.
  # BGG is a free HTTP pull — a fresh pull needs no confirm at all; a re-pull
  # confirms only because it replaces the current data.
  defp regen_confirm(:bgg, true),
    do: "Re-pull the BoardGameGeek data? This replaces the current data."

  defp regen_confirm(:bgg, false), do: nil

  defp regen_confirm(_id, true),
    do: "Re-run this step? It spends LLM budget and replaces the current result."

  defp regen_confirm(_id, false), do: "Generate this step? It spends LLM budget."

  ## Inline job log ------------------------------------------------------------

  # Per-step job history: the newest run with its event stream, then up to two
  # older runs as one-line summaries. Times are UTC, same as the DevTools panel.
  attr :log, :any, default: nil

  defp step_log(assigns) do
    ~H"""
    <div
      :if={@log}
      style="margin-top:0.7rem;border-top:1px dashed var(--border-subtle);padding-top:0.5rem"
    >
      <div style="font-size:0.62rem;font-weight:700;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);margin-bottom:0.3rem">
        Job log
      </div>
      <% [latest | older] = @log.runs %>
      <div style="display:flex;gap:0.5rem;align-items:baseline;flex-wrap:wrap;font-size:0.72rem;color:var(--text-secondary)">
        <span style={run_state_style(latest.state)}>{latest.state}</span>
        <span style="font-weight:600">{latest.label}</span>
        <span style="color:var(--text-muted)">{fmt_run_time(latest)}</span>
        <span :if={latest.summary} style="color:var(--text-muted)">— {latest.summary}</span>
      </div>
      <div
        :if={@log.events != []}
        style="margin-top:0.35rem;max-height:9rem;overflow:auto;background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.35rem;padding:0.4rem 0.55rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.68rem;line-height:1.5"
      >
        <div :for={e <- @log.events} style={event_style(e.level)}>
          <span style="color:var(--text-muted)">{fmt_event_time(e.inserted_at)}</span>
          {e.message}
        </div>
      </div>
      <div :for={r <- older} style="margin-top:0.25rem;font-size:0.68rem;color:var(--text-muted)">
        <span style={run_state_style(r.state)}>{r.state}</span>
        {fmt_run_time(r)}<span :if={r.summary}> — {r.summary}</span>
      </div>
    </div>
    """
  end

  defp run_state_style("done"), do: "color:var(--green);font-weight:700"
  defp run_state_style("failed"), do: "color:var(--red);font-weight:700"
  defp run_state_style("running"), do: "color:var(--accent);font-weight:700"
  defp run_state_style(_), do: "color:var(--text-muted);font-weight:700"

  defp event_style("error"), do: "color:var(--red)"
  defp event_style("warn"), do: "color:var(--yellow)"
  defp event_style(_), do: "color:var(--text-secondary)"

  defp fmt_run_time(%{started_at: t}) when is_struct(t), do: Calendar.strftime(t, "%b %d %H:%M")
  defp fmt_run_time(_), do: ""

  defp fmt_event_time(t) when is_struct(t), do: Calendar.strftime(t, "%H:%M:%S")
  defp fmt_event_time(_), do: ""

  # Where each step's output is viewed or managed. Player-facing artifacts link
  # to the live game page; the cheat sheet has its own view; everything in the
  # required ladder is managed on the edit page.
  defp step_link(:cheat_sheet, game), do: %{href: ~p"/games/#{game}/cheatsheet", label: "View"}

  defp step_link(id, game) when id in [:suggestions, :setup, :did_you_know, :voices, :theme],
    do: %{href: ~p"/games/#{game}", label: "View on game page"}

  # Categories are managed in place on this page now — no edit-page round-trip.
  defp step_link(:categories, _game), do: nil

  # BGG is edited in the details tab. Pin the tab explicitly — without it the
  # edit page restores whatever tab the admin last used (e.g. the cheat sheet).
  defp step_link(:bgg, game),
    do: %{href: ~p"/games/#{game}/edit?#{%{tab: "details"}}", label: "Manage on edit page"}

  # The required ladder (source/extract/review/cleanup/embed) is managed on the
  # Manage Rulebooks tab.
  defp step_link(_id, game),
    do: %{href: ~p"/games/#{game}/edit?#{%{tab: "manage"}}", label: "Manage on edit page"}

  # bgg_data is an unstructured BGG payload — surface only its scalar fields as a
  # compact key/value list, truncated, so we don't have to know the shape.
  defp bgg_rows(%{} = m) do
    m
    |> Enum.filter(fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) end)
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.take(10)
    |> Enum.map(fn {k, v} -> {k, truncate(to_string(v), 140)} end)
  end

  defp bgg_rows(_), do: []

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s
  end

  defp truncate(s, _n), do: to_string(s)

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem">
      <div style="font-size:0.65rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);font-weight:700">
        {@label}
      </div>
      <div style="font-size:1.15rem;font-weight:700;color:var(--text);margin-top:0.15rem">
        {@value}
      </div>
    </div>
    """
  end

  # Contextual jump to where a human-action step is handled (source upload and
  # page review both live in the edit page's rulebook manager). Automated steps
  # return nil — the Prepare button drives those.
  defp step_action(%{state: :done}, _game), do: nil
  defp step_action(%{id: :source}, game), do: %{href: ~p"/games/#{game}/edit", label: "Upload"}
  # Only offer Review once there are extracted pages to review (state :pending).
  # While extraction is still pending the step is :blocked — nothing to review.
  defp step_action(%{id: :review, state: :pending}, game),
    do: %{href: ~p"/games/#{game}/edit", label: "Review"}

  defp step_action(_step, _game), do: nil

  defp pause_message(%{pause_reason: "needs_bgg"} = assigns) do
    ~H"""
    BoardGameGeek data must be pulled first — set a BGG ID on the <.link
      navigate={~p"/games/#{@game}/edit?#{%{tab: "details"}}"}
      style="color:var(--accent);font-weight:600"
    >
      edit page
    </.link>, then re-click Prepare to resume.
    """
  end

  defp pause_message(%{pause_reason: "needs_source"} = assigns) do
    ~H"""
    Upload a rulebook source first — <.link
      navigate={~p"/games/#{@game}/edit"}
      style="color:var(--accent);font-weight:600"
    >
      go to the edit page
    </.link>.
    """
  end

  defp pause_message(%{pause_reason: "needs_extract"} = assigns) do
    ~H"""
    Extraction incomplete — waiting on text extraction before the pipeline can continue.
    """
  end

  defp pause_message(%{pause_reason: "needs_review"} = assigns) do
    ~H"""
    {fmt_int(@review_pages)} low-confidence {ngettext("page needs", "pages need", @review_pages)} review — <.link
      navigate={~p"/games/#{@game}/edit"}
      style="color:var(--accent);font-weight:600"
    >
      review them on the edit page
    </.link>, then re-click Prepare to resume.
    """
  end

  defp pause_message(assigns), do: ~H""

  ## Cost helpers ------------------------------------------------------------

  # Sum the actual logged spend for a step from `cost_by_operation_for_game/1`
  # rows, or `nil` when the step has no tracked operations / no logged spend.
  defp step_actual_cost(step, by_operation) do
    case Map.get(@step_operations, step) do
      nil ->
        nil

      [] ->
        nil

      ops ->
        rows = Enum.filter(by_operation, &(&1.operation in ops))

        if rows == [] do
          nil
        else
          Enum.reduce(rows, 0.0, &(&1.cost + &2))
        end
    end
  end

  # An LLM step whose estimate rounds to $0.0000 can't really cost nothing — it's
  # unknown (e.g. extract/embed before extraction, when the page count isn't yet
  # known). Show "—" rather than a misleading $0.00.
  defp est_label(_step, est) when is_number(est) and est < 0.00005, do: "est. —"
  defp est_label(_step, est), do: "est. $#{fmt_cost(est)}"

  defp cost_or_dash(nil), do: "—"
  defp cost_or_dash(usd), do: "$#{fmt_cost(usd)}"

  # Labels of required steps not yet done, for the disabled publish button's tooltip.
  defp remaining_required_labels(steps) do
    steps
    |> Enum.filter(&(&1.category == :required and &1.state != :done))
    |> Enum.map_join(", ", & &1.label)
  end

  defp fmt_cost(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)
  defp fmt_cost(_), do: "0.00"

  defp fmt_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp fmt_int(_), do: "0"

  ## Style helpers -----------------------------------------------------------

  defp chip_style(:done),
    do: "background:color-mix(in srgb,var(--green) 20%,var(--bg-surface));color:var(--green)"

  defp chip_style(:blocked),
    do: "background:var(--bg-subtle);color:var(--text-muted)"

  defp chip_style(_),
    do: "background:var(--bg-subtle);color:var(--text-secondary)"

  defp chip_label(:done), do: "Done"
  defp chip_label(:blocked), do: "Blocked"
  defp chip_label(_), do: "Pending"

  defp tag_style(:required), do: "color:var(--accent)"
  defp tag_style(_), do: "color:var(--text-muted)"
end
