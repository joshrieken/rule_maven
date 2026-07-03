defmodule RuleMavenWeb.GameLive.Form do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, Repo, RulebookDownloader, Settings, CheatSheet}
  import Ecto.Query
  alias RuleMaven.Games.Document

  @max_pdfs 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        game: nil,
        source_entries: [],
        # Source ids with a single-page re-extraction job in flight (=> true), so
        # the review badge can show a busy state until {:reextract_done} arrives.
        reextracting: %{},
        game_changeset: nil,
        download_url: "",
        download_label: "",
        downloading: false,
        download_stage: nil,
        download_error: nil,
        download_ok: false,
        confirm_delete_source_id: nil,
        searching: false,
        bgg_results: [],
        search_error: nil,
        confirm_clear: false,
        confirm_clear_sources: false,
        confirm_delete_game: false,
        confirm_delete_cheat: false,
        question_count: 0,
        generating: false,
        bgg_gate_bypassed: false,
        bgg_refresh_pending: false,
        expansion_prompt: false,
        exp_syncing: false,
        exp_sync_progress: nil,
        cheat_error: nil,
        cheat_content: nil,
        cheat_status: nil,
        cheat_provider: nil,
        cheat_model: nil,
        cheat_elapsed: nil,
        cheat_started_at: nil,
        cheat_level: "compact",
        cheat_refresh: 0,
        tab: "rulebook",
        included_expansions: %{},
        bgg_search: "",
        bgg_searching: false,
        bgg_search_results: [],
        bgg_search_error: nil,
        suggestions: [],
        dyk_facts: [],
        regenerating_dyk: false,
        regenerating_theme: false,
        setup_checklist: nil,
        regenerating_setup: false,
        # Which Generated-tab sections are expanded. Server-controlled so a
        # re-render (e.g. clicking Generate) doesn't re-assert a hardcoded `open`
        # and reopen sections the user collapsed. All open by default.
        open_sections: MapSet.new(["suggestions", "dyk", "setup", "categories", "theme"]),
        # Per-source HTML-regen result for inline feedback: source_id => :ok | :error.
        regen_html_status: %{},
        regenerating_suggestions: false,
        uploading_pdfs: false,
        draft_categories: [],
        saved_categories: [],
        regenerating_categories: false,
        parent_query: "",
        parent_results: [],
        parent_selected_id: nil,
        parent_selected_name: nil,
        extra_bases: [],
        cleaning: %{},
        # Which rulebook source the Manage tab shows (one at a time, picker/j-k
        # selectable). nil → falls back to the first source in the template.
        selected_source_id: nil,
        # Source ids freshly added by upload/download — drives the "clean now?"
        # prompt on the Manage tab.
        cleanup_subscribed: false,
        expanded_source_id: nil,
        reader_mode: "paginated",
        # Current page index per source entry (id => idx) for the inline + modal
        # paginated views.
        source_page: %{},
        # Manual "page 1 is on sheet N" entry per source (id => string), for the
        # detection-failed fallback numbering.
        page_one_input: %{},
        # Which text layer each source shows (id => "original"|"edited"|"cleaned").
        # Unset sources fall back to the most-refined layer present.
        editor_tab: %{}
      )
      |> allow_upload(:rulebook_pdfs,
        accept: ~w(.pdf .docx .odt .html .htm .xlsx .csv .txt .md .png .jpg .jpeg .webp .gif),
        max_entries: @max_pdfs,
        max_file_size: 50_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cond do
      not RuleMaven.Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply,
         socket
         |> put_flash(:error, "You don't have permission to do that.")
         |> push_navigate(to: ~p"/")}

      match?(%{"id" => _}, params) and is_nil(Games.get_game_by_token(params["id"])) ->
        {:noreply,
         socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      true ->
        do_handle_params(params, socket)
    end
  end

  defp do_handle_params(params, socket) do
    socket =
      case params do
        %{"id" => id} ->
          game = Games.get_game_by_token!(id)

          sources =
            game
            |> Games.list_rulebook_sources()
            |> Enum.with_index()
            |> Enum.map(fn {s, i} -> source_entry(s, i) end)

          # Cleaned text is persisted straight into each document's pages, so the
          # source entries already carry it — no overlay needed.
          entries = sources

          cheat_status = CheatSheet.status(game.id)
          cheat_content = CheatSheet.stored_content(game.id)
          cheat_error = CheatSheet.stored_error(game.id)
          cheat_provider = CheatSheet.stored_provider(game.id)
          cheat_model = CheatSheet.stored_model(game.id)
          cheat_elapsed = CheatSheet.stored_elapsed(game.id)
          cheat_started_at = CheatSheet.stored_started(game.id)
          cheat_level = CheatSheet.stored_level(game.id) || "compact"
          cancelled = CheatSheet.cancelled?(game.id)

          {cheat_status, cheat_content, cheat_error} =
            if cancelled && cheat_status in ["compressing", "generating"] do
              CheatSheet.clear(game.id)
              {nil, nil, nil}
            else
              {cheat_status, cheat_content, cheat_error}
            end

          socket =
            assign(socket,
              game: game,
              source_entries: entries,
              expansions: Games.expansions_for(game),
              cheat_expansions: Games.expansions_with_documents(game),
              game_changeset: Games.change_game(game),
              question_count: Games.question_count(game),
              cheat_status: cheat_status,
              cheat_content: cheat_content,
              cheat_error: cheat_error,
              cheat_provider: cheat_provider,
              cheat_model: cheat_model,
              cheat_elapsed: cheat_elapsed,
              cheat_started_at: cheat_started_at,
              cheat_level: cheat_level
            )

          if cheat_status in ["compressing", "generating"] do
            Process.send_after(self(), :poll_cheat_status, 2000)
          end

          # Follow any in-flight cleanup for this game. Subscribe once (this runs
          # again on every tab patch), and seed the progress map from Settings so
          # a remount immediately shows "Cleaning d/t…" instead of the button.
          socket =
            if connected?(socket) and not socket.assigns.cleanup_subscribed do
              Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game_cleanup:#{game.id}")
              # Results of the suggestion/category/cheat-sheet Oban workers arrive
              # via PubSub (the workers can't message this LiveView's pid).
              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.SuggestionsWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.CategoriesWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.CheatSheetGenWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.DidYouKnowWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.Setup.topic(game.id))

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.DownloadWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.BggEnrichWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.ThemePaletteWorker.topic(game.id)
              )

              Phoenix.PubSub.subscribe(
                RuleMaven.PubSub,
                RuleMaven.Workers.ExpansionSyncWorker.topic(game.id)
              )

              # Re-seed an in-flight expansion sync so a remount shows progress.
              progress = Settings.get(RuleMaven.Workers.ExpansionSyncWorker.key(game.id))

              socket
              |> assign(
                cleanup_subscribed: true,
                exp_syncing: not is_nil(progress),
                exp_sync_progress: progress
              )
            else
              socket
            end

          socket =
            assign(socket,
              cleaning: seed_cleaning(entries),
              reextracting: seed_reextracting(entries)
            )

          # Follow an in-flight download (durable Oban job) across a remount.
          socket =
            assign(socket,
              downloading: RuleMaven.Workers.DownloadWorker.running?(game.id),
              download_error: Settings.get("download_error_#{game.id}")
            )

          # Tab restore: an explicit ?tab= wins (in-app navigation), else the
          # per-game choice remembered in localStorage, else a sensible default
          # (Manage once a rulebook exists, else Upload).
          default_tab = if entries == [], do: "rulebook", else: "manage"
          tab = params["tab"] || restore_edit_tab(socket, game.id) || default_tab

          # Seed the per-source last page/sheet from localStorage, but only on the
          # first load — later patches (e.g. tab switches) must not stomp the
          # page the user has navigated to this session.
          source_page =
            if socket.assigns.source_page == %{},
              do: restore_source_page(socket, game.id),
              else: socket.assigns.source_page

          socket = assign(socket, tab: tab, source_page: source_page)

          suggestions =
            case RuleMaven.Settings.get("suggestions_#{game.id}") do
              nil ->
                []

              json ->
                json
                |> Jason.decode!()
                |> Enum.map(fn %{"category" => c, "questions" => qs} ->
                  %{category: c, questions: qs}
                end)
            end

          dyk_facts =
            case RuleMaven.Settings.get("did_you_know_#{game.id}") do
              nil -> []
              json -> Jason.decode!(json)
            end

          # Re-seed the in-flight "Generating…" state from the durable Oban job so
          # it survives a refresh instead of falling back to the "Generate" button.
          socket =
            assign(socket,
              suggestions: suggestions,
              dyk_facts: dyk_facts,
              regenerating_dyk: RuleMaven.Workers.DidYouKnowWorker.running?(game.id),
              regenerating_theme: RuleMaven.Workers.ThemePaletteWorker.running?(game.id),
              setup_checklist: RuleMaven.Setup.stored_checklist(game.id),
              regenerating_setup: RuleMaven.Setup.status(game.id) == "generating"
            )

          draft_categories =
            case RuleMaven.Settings.get("categories_#{game.id}") do
              nil ->
                []

              json ->
                json
                |> Jason.decode!()
                |> Enum.map(fn %{"name" => n, "description" => d} ->
                  %{name: n, description: d}
                end)
            end

          saved_categories = RuleMaven.Games.list_game_categories(game)

          socket =
            assign(socket, draft_categories: draft_categories, saved_categories: saved_categories)

          assign_parent_state(socket, game)

        _ ->
          changeset = Games.change_game(%Games.Game{})

          assign(socket,
            game: nil,
            source_entries: [],
            expansions: [],
            cheat_expansions: [],
            game_changeset: changeset
          )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_source", _params, socket) do
    entries = socket.assigns.source_entries
    next_id = (Enum.map(entries, & &1.id) ++ [-1]) |> Enum.max() |> Kernel.+(1)

    new_entry = %{
      id: next_id,
      source_id: nil,
      label: "",
      kind: "rulebook",
      text: "",
      pages: [%{index: 0, sheet: 1, printed: nil, text: "", cleaned: nil}],
      pdf_path: nil,
      html_path: nil
    }

    {:noreply, assign(socket, source_entries: entries ++ [new_entry])}
  end

  # Set the document kind for one source entry. The select lives inside the
  # save form, so LiveView serializes the whole form on change; phx-value-*
  # is NOT sent for change events, so the entry id is encoded in the select's
  # name ("kind_<id>") and read back from _target (same pattern as
  # set_source_page/pagesel_<id> above).
  @impl true
  def handle_event("set_kind", %{"_target" => ["kind_" <> id_str]} = params, socket) do
    id = String.to_integer(id_str)
    kind = params["kind_" <> id_str]

    entries =
      Enum.map(socket.assigns.source_entries, fn e ->
        if e.id == id do
          # Persist immediately for an already-saved source, so the kind sticks
          # without routing through the label-keyed form save. New, unsaved
          # entries persist on save instead.
          if e[:source_id] do
            doc = Games.get_document!(e.source_id)
            Games.update_document(doc, %{kind: kind})
          end

          %{e | kind: kind}
        else
          e
        end
      end)

    {:noreply, assign(socket, source_entries: entries)}
  end

  @impl true
  def handle_event("remove_source", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entries = Enum.reject(socket.assigns.source_entries, &(&1.id == id))
    {:noreply, assign(socket, source_entries: entries)}
  end

  @impl true
  def handle_event("delete_source", %{"source_id" => source_id}, socket) do
    {:noreply, assign(socket, confirm_delete_source_id: String.to_integer(source_id))}
  end

  def handle_event("confirm_delete_source", %{"source_id" => source_id}, socket) do
    source_id = String.to_integer(source_id)

    source =
      socket.assigns.game
      |> Games.list_rulebook_sources()
      |> Enum.find(&(&1.id == source_id))

    if source do
      Games.delete_rulebook_source(source)
    end

    entries = Enum.reject(socket.assigns.source_entries, &(&1[:source_id] == source_id))
    {:noreply, assign(socket, source_entries: entries, confirm_delete_source_id: nil)}
  end

  def handle_event("cancel_delete_source", _params, socket) do
    {:noreply, assign(socket, confirm_delete_source_id: nil)}
  end

  @impl true
  def handle_event("confirm_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: true)}
  end

  @impl true
  def handle_event("cancel_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: false)}
  end

  @impl true
  def handle_event("clear_questions", _params, socket) do
    game = socket.assigns.game
    {count, _} = Games.delete_all_questions(game)

    {:noreply,
     socket
     |> assign(confirm_clear: false, question_count: 0)
     |> put_flash(:info, "Cleared #{count} question(s) for #{game.name}.")}
  end

  def handle_event("confirm_clear_sources", _params, socket) do
    {:noreply, assign(socket, confirm_clear_sources: true)}
  end

  def handle_event("cancel_clear_sources", _params, socket) do
    {:noreply, assign(socket, confirm_clear_sources: false)}
  end

  def handle_event("confirm_delete_game", _params, socket) do
    {:noreply, assign(socket, confirm_delete_game: true)}
  end

  def handle_event("cancel_delete_game", _params, socket) do
    {:noreply, assign(socket, confirm_delete_game: false)}
  end

  def handle_event("delete_game", _params, socket) do
    game = socket.assigns.game
    Games.delete_game(game)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{game.name} and all associated data.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_event("clear_sources", _params, socket) do
    game = socket.assigns.game
    {count, _} = Repo.delete_all(from d in Document, where: d.game_id == ^game.id)

    {:noreply,
     socket
     |> assign(confirm_clear_sources: false, source_entries: [])
     |> put_flash(:info, "Cleared #{count} rulebook source(s) for #{game.name}.")}
  end

  @impl true
  # Escape hatch from the pre-sync gate: BGG enrichment may never land (BGG
  # down, no data for this id). Let the admin into the full editor anyway.
  def handle_event("bypass_bgg_gate", _params, socket) do
    {:noreply, assign(socket, bgg_gate_bypassed: true)}
  end

  # Discover + link this game's expansions from BGG and refresh each one's
  # detail. Durable + non-blocking via Oban; progress arrives over PubSub.
  def handle_event("pull_expansions", _params, socket) do
    if socket.assigns.game do
      RuleMaven.Workers.ExpansionSyncWorker.enqueue(socket.assigns.game.id)

      {:noreply,
       socket
       |> assign(exp_syncing: true, exp_sync_progress: nil, expansion_prompt: false)
       |> put_flash(:info, "Pulling expansions from BGG…")}
    else
      {:noreply, socket}
    end
  end

  # Dismiss the post-enrich "pull expansions now?" prompt (the admin can still
  # use the Pull button in the expansions section later).
  def handle_event("dismiss_expansion_prompt", _params, socket) do
    {:noreply, assign(socket, expansion_prompt: false)}
  end

  def handle_event("refresh_bgg", _params, socket) do
    # Durable + non-blocking: enqueue the BGG pull and let the result arrive over
    # PubSub (subscribed in mount) instead of blocking the LiveView process.
    %{game_id: socket.assigns.game.id}
    |> RuleMaven.Workers.BggEnrichWorker.new()
    |> Oban.insert()

    # Mark this as a user-initiated refresh so the enrich result can offer to
    # pull expansions now (creation-time enrich doesn't set this, so it won't).
    {:noreply, assign(socket, generating: true, bgg_refresh_pending: true)}
  end

  def handle_event("regenerate_html", %{"id" => id_str}, socket) do
    # Re-render the source's "View as HTML" file from its current saved text, then
    # flag the result inline next to the button (flash isn't visible on this page).
    sid = parse_id(id_str)

    status =
      case Games.get_document(sid) do
        %Document{} = doc -> Games.regenerate_document_html(doc)
        _ -> :error
      end

    status_map = Map.put(socket.assigns.regen_html_status, sid, status)
    {:noreply, assign(socket, regen_html_status: status_map)}
  end

  # Clean a single page (the one shown in the editor), durably via the same
  # CleanupWorker — always a fresh clean from that page's original extraction.
  def handle_event("cleanup_page", %{"id" => id, "page" => page}, socket) do
    id = String.to_integer(id)
    page = String.to_integer(page)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    socket =
      if entry && entry.source_id,
        do: start_page_cleanup(socket, entry.source_id, page),
        else: socket

    {:noreply, socket}
  end

  def handle_event("cleanup_source", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    socket =
      if entry && entry.source_id,
        do: start_cleanup(socket, entry.source_id, :raw),
        else: socket

    {:noreply, socket}
  end

  # "Clean again": a second cleanup pass over the already-cleaned text to scrub
  # remaining junk (does not reset to the raw extraction).
  def handle_event("reclean_source", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    socket =
      if entry && entry.source_id,
        do: start_cleanup(socket, entry.source_id, :again),
        else: socket

    {:noreply, socket}
  end

  def handle_event("expand_source", %{"id" => id}, socket) do
    {:noreply, assign(socket, expanded_source_id: String.to_integer(id))}
  end

  def handle_event("close_source", _params, socket) do
    {:noreply, assign(socket, expanded_source_id: nil)}
  end

  # Manage tab shows one source at a time; the dropdown picks which.
  def handle_event("select_inline_source", %{"inline_source" => id}, socket) do
    {:noreply, assign(socket, selected_source_id: parse_id(id))}
  end

  # j / k step through the Manage-tab sources without leaving the keyboard.
  def handle_event("cycle_inline_source", %{"delta" => delta}, socket) do
    entries = socket.assigns.source_entries
    cur = current_inline_source_id(socket)

    with d when d in [-1, 1] <- parse_delta(delta),
         i when is_integer(i) <- Enum.find_index(entries, &(&1.id == cur)),
         true <- length(entries) > 1 do
      next = Enum.at(entries, Integer.mod(i + d, length(entries)))
      {:noreply, assign(socket, selected_source_id: next.id)}
    else
      _ -> {:noreply, socket}
    end
  end

  # j / k in the reader cycle which rulebook source is open (vim-style: h/l page,
  # j/k switch source). Wraps around; no-op with a single source. Reset the page
  # to the top of the newly-opened source and scroll the reader up.
  def handle_event("cycle_source", %{"delta" => delta}, socket) do
    entries = socket.assigns.source_entries
    cur = socket.assigns.expanded_source_id

    with d when d in [-1, 1] <- parse_delta(delta),
         i when is_integer(i) <- Enum.find_index(entries, &(&1.id == cur)),
         true <- length(entries) > 1 do
      next = Enum.at(entries, Integer.mod(i + d, length(entries)))
      {:noreply, assign(socket, expanded_source_id: next.id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_reader_mode", %{"mode" => mode}, socket)
      when mode in ~w(scroll paginated) do
    {:noreply, assign(socket, reader_mode: mode)}
  end

  # Set the current page index for one source entry (inline + modal share this).
  # The select lives inside the save form, so LiveView serializes the whole form
  # on change; the entry id is encoded in the select's name ("pagesel_<id>") and
  # read back from _target.
  def handle_event("set_source_page", %{"_target" => [target]} = params, socket) do
    case target do
      "pagesel_" <> id ->
        id = String.to_integer(id)
        page = String.to_integer(params[target] || "0")
        {:noreply, persist_source_page(socket, id, page)}

      _ ->
        {:noreply, socket}
    end
  end

  # Edit one page's body text. The textarea name encodes entry id, page index and
  # which layer is being edited ("pg_<id>_<idx>_<layer>" inline, "pgm_..." in the
  # modal; layer is "orig" for unsaved manual entries, else "edit"). Both views
  # feed the same socket state so they stay in sync; full_text (effective text) is
  # kept current so cleanup/expand checks and Save stay consistent.
  def handle_event("edit_page", %{"_target" => [target]} = params, socket) do
    case Regex.run(~r/^pgm?_(\d+)_(\d+)_(orig|clean)$/, target) do
      [_, id, idx, layer] ->
        id = String.to_integer(id)
        idx = String.to_integer(idx)
        text = params[target] || ""
        field = if layer == "orig", do: :text, else: :cleaned

        entries =
          Enum.map(socket.assigns.source_entries, fn e ->
            if e.id == id and idx < length(e.pages) do
              pages = List.update_at(e.pages, idx, &Map.put(&1, field, text))
              %{e | pages: pages, text: Games.rebuild_full_text(pages)}
            else
              e
            end
          end)

        {:noreply, assign(socket, source_entries: entries)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_editor_tab", %{"id" => id, "tab" => tab}, socket)
      when tab in ~w(original cleaned) do
    id = String.to_integer(id)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    # Ignore a switch to Cleaned when no cleaned text exists yet (the tab is
    # disabled client-side; this guards a forged/stale event too).
    if (tab == "cleaned" and entry) && not cleaned_available?(entry) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, editor_tab: Map.put(socket.assigns.editor_tab, id, tab))}
    end
  end

  def handle_event("source_page_step", %{"id" => id, "delta" => delta}, socket) do
    id = String.to_integer(id)
    cur = Map.get(socket.assigns.source_page, id, 0)
    # Clamp so keyboard paging (which can fire past the ends) stays in range.
    count =
      case Enum.find(socket.assigns.source_entries, &(&1.id == id)) do
        %{pages: pages} -> length(pages)
        _ -> 0
      end

    next = (cur + String.to_integer(delta)) |> max(0) |> min(max(count - 1, 0))
    {:noreply, persist_source_page(socket, id, next)}
  end

  # Stash the "page 1 is on sheet N" input as the user types (name encodes the
  # entry id, read from _target), so the Number-pages button has it on click.
  def handle_event("set_page_one_input", %{"_target" => [target]} = params, socket) do
    case target do
      "pageone_" <> id ->
        id = String.to_integer(id)
        val = String.trim(params[target] || "")

        {:noreply,
         assign(socket, page_one_input: Map.put(socket.assigns.page_one_input, id, val))}

      _ ->
        {:noreply, socket}
    end
  end

  # Manual page numbering fallback when detection failed: the user says which
  # physical sheet is printed "Page 1", and we number the rest from there.
  # For a saved source we persist + re-chunk immediately, so a later Wipe & clean
  # (which works off the stored doc and reloads pages from the DB) can't blow the
  # numbering away. A not-yet-saved source has no doc to write to, so it stays
  # in-memory and rides along on the next Save.
  def handle_event("set_page_one", %{"id" => id}, socket) do
    id = String.to_integer(id)
    sheet_str = socket.assigns.page_one_input |> Map.get(id, "") |> String.trim()

    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    case {entry, Integer.parse(sheet_str)} do
      {nil, _} ->
        {:noreply, socket}

      {%{source_id: sid}, {sheet, _}} when is_integer(sid) and sheet >= 1 ->
        {:ok, _doc} = Games.set_printed_anchor(Games.get_document!(sid), sheet)

        entries =
          Enum.map(socket.assigns.source_entries, fn e ->
            if e.id == id, do: reload_entry(e), else: e
          end)

        {:noreply,
         socket
         |> assign(source_entries: entries)
         |> put_flash(:info, "Numbered pages from sheet #{sheet}.")}

      {entry, {sheet, _}} when sheet >= 1 ->
        pages = Games.assign_printed_from_anchor(entry.pages, sheet)
        new_entry = %{entry | pages: pages, text: Games.rebuild_full_text(pages)}

        entries =
          Enum.map(socket.assigns.source_entries, fn e ->
            if e.id == id, do: new_entry, else: e
          end)

        {:noreply,
         socket
         |> assign(source_entries: entries)
         |> put_flash(:info, "Numbered pages from sheet #{sheet}. Save to apply.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Enter the sheet number that shows printed page 1.")}
    end
  end

  # Re-extract one low-confidence page at the top tier (strong model + critic),
  # durably via Oban. Marks the source busy; {:reextract_done} reloads it.
  def handle_event("reextract_page", %{"id" => id, "page" => page}, socket) do
    id = String.to_integer(id)
    page = String.to_integer(page)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    with %{source_id: sid} when is_integer(sid) <- entry,
         %{index: index} <- Enum.at(entry.pages, page) do
      RuleMaven.Workers.ReextractPageWorker.enqueue(sid, index)

      {:noreply,
       socket
       |> start_reextract(sid, 1)
       |> put_flash(:info, "Re-extracting page with the strongest model…")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Save the rulebook before re-extracting a page.")}
    end
  end

  # Re-extract every page in a source the gate flagged as low-confidence, in one
  # go. Each page is its own durable Oban job; the source stays busy (editing
  # locked, progress streaming) until the last one reports back.
  def handle_event("reextract_all", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entry = Enum.find(socket.assigns.source_entries, &(&1.id == id))

    with %{source_id: sid} when is_integer(sid) <- entry,
         flagged when flagged != [] <- Enum.filter(entry.pages, & &1[:needs_review]) do
      Enum.each(flagged, &RuleMaven.Workers.ReextractPageWorker.enqueue(sid, &1.index))
      n = length(flagged)

      {:noreply,
       socket
       |> start_reextract(sid, n)
       |> put_flash(
         :info,
         "Re-extracting #{n} flagged page#{if n == 1, do: "", else: "s"} with the strongest model…"
       )}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Save the rulebook before re-extracting pages.")}

      [] ->
        {:noreply, put_flash(socket, :info, "No flagged pages to re-extract.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Save the rulebook before re-extracting pages.")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if socket.assigns.game do
      {:noreply,
       socket
       |> push_event("save_edit_tab", %{game_id: socket.assigns.game.id, tab: tab})
       |> push_patch(to: ~p"/games/#{socket.assigns.game}/edit?tab=#{tab}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_cheat_expansion", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    included = socket.assigns.included_expansions

    included =
      if included[id] do
        Map.delete(included, id)
      else
        Map.put(included, id, true)
      end

    {:noreply, assign(socket, included_expansions: included)}
  end

  @impl true
  def handle_event("unlink_expansion", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    Games.unlink_expansion(id, socket.assigns.game.id)

    game = Games.get_game!(socket.assigns.game.id)

    socket =
      assign(socket,
        game: game,
        expansions: Games.expansions_for(game),
        cheat_expansions: Games.expansions_with_documents(game)
      )

    {:noreply, assign_parent_state(socket, game)}
  end

  @impl true
  def handle_event("generate_cheat", %{"level" => level} = params, socket) do
    game = socket.assigns.game
    expansion_ids = parse_expansion_ids(params)
    CheatSheet.generate_async(game, level, expansion_ids)
    now = System.system_time(:second)

    {:noreply,
     socket
     |> assign(
       cheat_status: "compressing",
       cheat_error: nil,
       cheat_content: nil,
       cheat_provider: RuleMaven.LLM.provider(),
       cheat_model: RuleMaven.LLM.model(),
       cheat_elapsed: 0,
       cheat_started_at: now,
       cheat_level: level
     )
     |> then(fn s ->
       Process.send_after(self(), :poll_cheat_status, 2000)
       s
     end)}
  end

  @impl true
  def handle_event("delete_cheat", _params, socket) do
    game = socket.assigns.game
    docs = Games.list_documents(game)

    if docs != [] do
      doc_id = hd(docs).id
      CheatSheet.list_versions(doc_id) |> Enum.each(&CheatSheet.delete_version/1)
    end

    CheatSheet.clear(game.id)

    {:noreply,
     socket
     |> assign(cheat_content: nil, cheat_error: nil, cheat_status: nil, cheat_started_at: nil)
     |> put_flash(:info, "All cheat sheet versions deleted.")}
  end

  @impl true
  def handle_event("confirm_delete_cheat", _params, socket) do
    game = socket.assigns.game
    docs = Games.list_documents(game)

    if docs != [] do
      doc_id = hd(docs).id
      CheatSheet.list_versions(doc_id) |> Enum.each(&CheatSheet.delete_version/1)
    end

    CheatSheet.clear(game.id)

    {:noreply,
     socket
     |> assign(confirm_delete_cheat: false, cheat_content: nil)
     |> put_flash(:info, "All cheat sheet versions deleted.")}
  end

  @impl true
  def handle_event("cancel_delete_cheat", _params, socket) do
    {:noreply, assign(socket, confirm_delete_cheat: false)}
  end

  @impl true
  def handle_event("cancel_cheat_content", _params, socket) do
    if socket.assigns.game, do: CheatSheet.clear(socket.assigns.game.id)

    {:noreply,
     assign(socket,
       cheat_content: nil,
       cheat_error: nil,
       cheat_status: nil,
       cheat_started_at: nil
     )}
  end

  @impl true
  def handle_event("save_cheat", %{"content" => content}, socket) do
    game = socket.assigns.game
    level = socket.assigns.cheat_level || "compact"
    refresh = socket.assigns.cheat_refresh + 1
    docs = Games.list_documents(game)

    if docs != [] do
      doc_id = hd(docs).id

      case CheatSheet.save_version(doc_id, content, level) do
        {:ok, _version} ->
          {:noreply,
           socket
           |> assign(
             cheat_content: nil,
             cheat_error: nil,
             cheat_status: nil,
             cheat_started_at: nil,
             cheat_refresh: refresh
           )
           |> put_flash(:info, "Cheat sheet saved!")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(cheat_refresh: refresh)
           |> put_flash(:error, "Failed to save: #{inspect(reason)}")}
      end
    else
      {:noreply,
       socket
       |> assign(cheat_refresh: refresh)
       |> put_flash(:error, "No rulebook document found.")}
    end
  end

  @impl true
  def handle_event("delete_version", %{"id" => id}, socket) do
    game = socket.assigns.game
    refresh = socket.assigns.cheat_refresh + 1

    case {game, Integer.parse(id)} do
      # /games/new has no game yet (socket.assigns.game is nil) —
      # get_version_for_game/2 pattern-matches a %Game{} struct, so a forged
      # event here would otherwise crash with FunctionClauseError.
      {nil, _} ->
        {:noreply, socket |> put_flash(:error, "Version not found.")}

      {_game, {version_id, _}} ->
        case CheatSheet.get_version_for_game(game, version_id) do
          nil ->
            {:noreply, socket |> put_flash(:error, "Version not found.")}

          version ->
            CheatSheet.delete_version(version)

            {:noreply,
             socket |> assign(cheat_refresh: refresh) |> put_flash(:info, "Version deleted.")}
        end

      {_game, :error} ->
        {:noreply, socket |> put_flash(:error, "Invalid version ID.")}
    end
  end

  @impl true
  def handle_event("set_active_version", %{"id" => id}, socket) do
    game = socket.assigns.game
    refresh = socket.assigns.cheat_refresh + 1

    case {game, Integer.parse(id)} do
      # See delete_version/2 above: /games/new has no game yet.
      {nil, _} ->
        {:noreply, socket |> put_flash(:error, "Version not found.")}

      {_game, {version_id, _}} ->
        case CheatSheet.get_version_for_game(game, version_id) do
          nil ->
            {:noreply, socket |> put_flash(:error, "Version not found.")}

          version ->
            CheatSheet.set_active(version)

            {:noreply,
             socket
             |> assign(cheat_refresh: refresh)
             |> put_flash(:info, "Version set as active.")}
        end

      {_game, :error} ->
        {:noreply, socket |> put_flash(:error, "Invalid version ID.")}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # Parent-game (expansion-of) typeahead. Avoids preloading the entire ~150k
  # catalog into a <select>; results are searched on demand.
  def handle_event("search_parent", %{"value" => query}, socket) do
    query = String.trim(query)

    results =
      if query == "" do
        []
      else
        query
        |> Games.search_catalog(limit: 15)
        |> Enum.reject(&(socket.assigns.game && &1.id == socket.assigns.game.id))
      end

    {:noreply, assign(socket, parent_query: query, parent_results: results)}
  end

  def handle_event("select_parent", %{"id" => id, "name" => _name}, socket) do
    base_id = String.to_integer(id)
    Games.link_expansion(socket.assigns.game.id, base_id)

    {:noreply, assign_parent_state(socket, socket.assigns.game)}
  end

  def handle_event("clear_parent", _params, socket) do
    if socket.assigns.parent_selected_id do
      Games.unlink_expansion(socket.assigns.game.id, socket.assigns.parent_selected_id)
    end

    {:noreply, assign_parent_state(socket, socket.assigns.game)}
  end

  @impl true
  def handle_event("download", %{"url" => url, "label" => label}, socket) do
    url = String.trim(url)
    label = String.trim(label)

    socket =
      assign(socket,
        downloading: true,
        download_stage: "Starting…",
        download_error: nil,
        download_ok: nil
      )

    if url == "" do
      {:noreply,
       assign(socket, downloading: false, download_stage: nil, download_error: "Enter a PDF URL")}
    else
      RuleMaven.Workers.DownloadWorker.enqueue(socket.assigns.game.id, "url", url, label)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("find_download", _params, socket) do
    socket =
      assign(socket,
        downloading: true,
        download_stage: "Starting…",
        download_error: nil,
        download_ok: nil
      )

    RuleMaven.Workers.DownloadWorker.enqueue(socket.assigns.game.id, "find")
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_download", _params, socket) do
    RuleMaven.Workers.DownloadWorker.cancel(socket.assigns.game.id)

    {:noreply,
     assign(socket,
       downloading: false,
       uploading_pdfs: false,
       download_stage: nil,
       download_error: nil
     )}
  end

  @impl true
  def handle_event("bgg_search", %{"search" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, bgg_search_results: [], bgg_search_error: nil)}
    else
      socket = assign(socket, bgg_search: query, bgg_searching: true, bgg_search_error: nil)

      # Run the BGG API call off the LiveView process so it stays responsive.
      socket =
        start_async(socket, :bgg_search, fn ->
          {query, RuleMaven.BGG.search(query)}
        end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("bgg_select", %{"id" => bgg_id_str, "name" => name}, socket) do
    require Logger
    Logger.debug("bgg_select: id=#{bgg_id_str} name=#{name}")

    {bgg_id, _} = Integer.parse(bgg_id_str)

    changeset =
      socket.assigns.game_changeset || RuleMaven.Games.change_game(%RuleMaven.Games.Game{})

    changeset = %{
      changeset
      | data: %{changeset.data | name: name, bgg_id: bgg_id},
        changes: Map.merge(changeset.changes, %{name: name, bgg_id: bgg_id})
    }

    socket =
      start_async(socket, :pull_bgg_info, fn ->
        {changeset, RuleMaven.BGG.fetch_game_info(changeset.data.bgg_id)}
      end)

    {:noreply,
     socket
     |> assign(
       game_changeset: changeset,
       bgg_search_results: [],
       bgg_search: ""
     )}
  end

  @impl true
  def handle_event("search_bgg", _params, socket) do
    game = socket.assigns.game
    socket = assign(socket, searching: true, bgg_results: [], search_error: nil)
    bgg_id = game.bgg_id

    # resolve_bgg_cookies/0 logs into BGG (with retry sleeps) — must not run on
    # the LiveView process. Do the whole login+search off-process.
    socket =
      start_async(socket, :search_bgg, fn ->
        cookies = resolve_bgg_cookies()
        {cookies, RulebookDownloader.find_on_bgg(bgg_id, cookies: cookies)}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search_download", %{"url" => url, "label" => label}, socket) do
    url = String.trim(url)
    label = String.trim(label)
    socket = assign(socket, downloading: true, download_stage: "Starting…", download_error: nil)
    RuleMaven.Workers.DownloadWorker.enqueue(socket.assigns.game.id, "url", url, label)
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"game" => game_params} = all_params, socket) do
    # Merge BGG-pulled data from changeset into params
    extra = socket.assigns.game_changeset.changes

    game_params =
      Map.merge(game_params, extra |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end))

    source_map =
      socket.assigns.source_entries
      |> Enum.map(fn entry ->
        label = all_params["label_#{entry.id}"] || ""

        # All three layers are kept current in socket state (edit_page + cleanup),
        # synced across the inline + expanded editors, so build straight from there.
        pages =
          entry.pages
          |> Enum.with_index()
          |> Enum.map(fn {p, i} ->
            %{
              index: i,
              sheet: p.sheet,
              printed: p.printed,
              text: p.text || "",
              cleaned: p[:cleaned]
            }
          end)

        {label,
         %{
           full_text: Games.rebuild_full_text(pages),
           pages: pages,
           pdf_path: nil,
           kind: entry[:kind] || "rulebook"
         }}
      end)
      |> Enum.filter(fn {l, %{pages: pages}} ->
        String.trim(l) != "" and
          Enum.any?(pages, &(String.trim(Games.effective_page_text(&1)) != ""))
      end)

    # Copy any pending PDF uploads into place now (consume_uploaded_entries deletes
    # the temp file once the callback returns). The source rows are created below,
    # after save_game. Failed copies are kept as error messages and surfaced via
    # flash — never silently dropped.
    {upload_files, upload_errors} =
      socket
      |> consume_uploaded_entries(:rulebook_pdfs, fn %{path: path}, entry ->
        label = entry.client_name |> Path.rootname() |> String.replace(~r/[_\-]/, " ")

        case save_uploaded_pdf(path, entry.client_name) do
          {:ok, pdf_path} -> {:ok, {:ok, %{pdf_path: pdf_path, label: label}}}
          {:error, reason} -> {:ok, {:error, "#{entry.client_name}: #{reason}"}}
        end
      end)
      |> split_upload_results()

    game = socket.assigns.game

    case save_game(socket, game, game_params, Map.new(source_map)) do
      {:ok, saved} ->
        # Ingest new uploads *after* save_game — it prunes existing sources not
        # present in the form's source_map, so ingesting earlier would delete the
        # ones we just added. Extraction is deferred, so this is a cheap
        # synchronous save; the source rows exist before we navigate, so the
        # prepare page never renders an empty pipeline.
        Enum.each(upload_files, fn %{pdf_path: p, label: l} ->
          RulebookDownloader.ingest_local(game, p, l)
        end)

        saved = flash_upload_errors(saved, upload_errors)

        # A save that brought in new PDF uploads lands on the prepare page (where
        # the Extract action lives), overriding save_game's default edit-page
        # redirect.
        if upload_files != [] do
          {:noreply,
           saved
           |> push_navigate(to: ~p"/games/#{game}/prepare")
           |> put_flash(:info, "Saved — extract from the prepare page.")}
        else
          {:noreply, saved}
        end

      {:error, errored} ->
        # Save failed: don't ingest uploads against unsaved state, don't
        # navigate — re-render the form with the changeset errors.
        {:noreply, flash_upload_errors(errored, upload_errors)}
    end
  end

  @impl true
  def handle_event("process_uploads", _params, socket) do
    game = socket.assigns.game

    # Extraction is deferred to the prepare page, so ingesting an upload is just a
    # file copy + a Document insert — cheap enough to do synchronously here. Doing
    # it inline means the source row exists *before* we navigate, so the prepare
    # page never renders an empty pipeline (no race). consume_uploaded_entries
    # deletes the temp file when the callback returns, so the copy must happen now.
    results =
      consume_uploaded_entries(socket, :rulebook_pdfs, fn %{path: path}, entry ->
        label = entry.client_name |> Path.rootname() |> String.replace(~r/[_\-]/, " ")

        with {:ok, pdf_path} <- save_uploaded_pdf(path, entry.client_name),
             {:ok, _src} <- RulebookDownloader.ingest_local(game, pdf_path, label) do
          {:ok, {:ok, label}}
        else
          {:error, reason} -> {:ok, {:error, "#{entry.client_name}: #{reason}"}}
        end
      end)

    saved = for {:ok, _label} <- results, do: :ok
    errors = for {:error, msg} <- results, do: msg

    socket =
      if saved != [] do
        socket
        |> put_flash(
          :info,
          "Saved #{length(saved)} rulebook(s) — extract them from the prepare page."
        )
        |> push_navigate(to: ~p"/games/#{game}/prepare")
      else
        socket
      end

    socket =
      if errors != [], do: put_flash(socket, :error, Enum.join(errors, "; ")), else: socket

    {:noreply, socket}
  end

  # Splits consume_uploaded_entries results into successfully copied files and
  # error messages. Public so the failure-counting logic is directly testable.
  @doc false
  def split_upload_results(results) do
    files = for {:ok, file} <- results, do: file
    errors = for {:error, msg} <- results, do: msg
    {files, errors}
  end

  @doc false
  def combine_error_messages(existing_error, new_errors) do
    upload_msg = "#{length(new_errors)} upload(s) failed: #{Enum.join(new_errors, "; ")}"

    case existing_error do
      nil -> upload_msg
      msg -> "#{msg} #{upload_msg}"
    end
  end

  # Re-derives the base-game picker assigns (parent_selected_id/_name,
  # extra_bases) straight from the DB. Must be called after every
  # link_expansion/unlink_expansion write touching this game as an expansion,
  # since a game can be linked to more than one base (BGG multi-parent
  # linking) — overwriting the assigns from event params instead of
  # re-deriving them clobbers whichever base isn't the one just
  # linked/unlinked out of the UI, even though it stays linked in the DB.
  defp assign_parent_state(socket, game) do
    bases = Games.base_games_for(game)
    parent = List.first(bases)

    assign(socket,
      parent_selected_id: parent && parent.id,
      parent_selected_name: parent && parent.name,
      extra_bases: Enum.drop(bases, 1),
      parent_query: "",
      parent_results: []
    )
  end

  defp flash_upload_errors(socket, []), do: socket

  defp flash_upload_errors(socket, errors) do
    upload_msg = "#{length(errors)} upload(s) failed: #{Enum.join(errors, "; ")}"

    case socket.assigns.flash["error"] do
      nil ->
        put_flash(socket, :error, upload_msg)

      existing_msg ->
        combined = combine_error_messages(existing_msg, errors)
        put_flash(socket, :error, combined)
    end
  end

  # Copies a freshly uploaded temp file into the static uploads dir under a
  # unique name. Returns the static-relative path for the extraction worker.
  defp save_uploaded_pdf(temp_path, client_name) do
    upload_dir = Application.app_dir(:rule_maven, "priv/static/uploads/rulebooks")
    File.mkdir_p!(upload_dir)

    pdf_path =
      Path.join("uploads/rulebooks", "#{System.system_time(:millisecond)}_#{client_name}")

    dest = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    case File.cp(temp_path, dest) do
      :ok -> {:ok, pdf_path}
      {:error, reason} -> {:error, "could not save file (#{reason})"}
    end
  end

  def handle_progress(:rulebook_pdfs, _entry, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:download_done, game_id, _pdf_path}, socket) do
    game = socket.assigns.game

    if game && game.id == game_id do
      # The source is saved; extraction/generation is deferred to the prepare
      # page, so send the admin straight there. push_navigate remounts a fresh
      # LiveView, so there's no need to reload source state into this socket.
      {:noreply,
       socket
       |> put_flash(:info, "Rulebook uploaded — extract it from the prepare page when ready.")
       |> push_navigate(to: ~p"/games/#{game}/prepare")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_error, game_id, reason}, socket) do
    if socket.assigns.game && socket.assigns.game.id == game_id do
      socket =
        socket
        |> assign(
          downloading: false,
          uploading_pdfs: false,
          download_stage: nil,
          download_error: reason
        )
        # Surface upload failures too (the upload panel doesn't show download_error).
        |> put_flash(:error, reason)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_progress, game_id, stage}, socket) do
    active? = socket.assigns.downloading or socket.assigns.uploading_pdfs

    if (socket.assigns.game && socket.assigns.game.id == game_id) and active? do
      {:noreply, assign(socket, download_stage: stage)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:suggestions_ready, qs}, socket) do
    {:noreply, assign(socket, suggestions: qs, regenerating_suggestions: false)}
  end

  @impl true
  def handle_info({:did_you_know_ready, facts}, socket) do
    {:noreply, assign(socket, dyk_facts: facts, regenerating_dyk: false)}
  end

  @impl true
  def handle_info({:setup_done, game_id}, socket) do
    if socket.assigns.game && socket.assigns.game.id == game_id do
      {:noreply,
       assign(socket,
         setup_checklist: RuleMaven.Setup.stored_checklist(game_id),
         regenerating_setup: false
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:categories_ready, cats}, socket) do
    {:noreply, assign(socket, draft_categories: cats, regenerating_categories: false)}
  end

  @impl true
  def handle_info({:categories_saved, saved}, socket) do
    # First generation auto-committed (nothing to blow away) — show the saved set,
    # no draft to review.
    {:noreply,
     socket
     |> assign(saved_categories: saved, draft_categories: [], regenerating_categories: false)
     |> put_flash(:info, "Generated and saved #{length(saved)} categories.")}
  end

  @impl true
  def handle_info({:page_cleaned, sid, idx, text, done, total}, socket) do
    # The cleanup worker persisted one page and broadcast it — swap that page
    # live and take the authoritative {done, total} the worker computed from its
    # durable counter (not a local recount, which the old code got wrong).
    entries =
      Enum.map(socket.assigns.source_entries, fn e ->
        if e.source_id == sid, do: put_page_cleaned(e, idx, text), else: e
      end)

    cleaning =
      if Map.has_key?(socket.assigns.cleaning, sid),
        do: Map.put(socket.assigns.cleaning, sid, {done, total}),
        else: socket.assigns.cleaning

    {:noreply, assign(socket, source_entries: entries, cleaning: cleaning)}
  end

  @impl true
  def handle_info({:cleanup_done, sid}, socket) do
    # Reload the source's pages from the DB so the form holds the final
    # persisted cleaned text, then drop the progress indicator.
    entries =
      Enum.map(socket.assigns.source_entries, fn e ->
        if e.source_id == sid, do: reload_entry(e), else: e
      end)

    {:noreply,
     socket
     |> assign(source_entries: entries, cleaning: Map.delete(socket.assigns.cleaning, sid))
     |> put_flash(:info, "Cleaned up the rulebook text.")}
  end

  # One page's re-extraction finished — reload that source from the DB (the worker
  # persisted the new page) and count the source's remaining jobs down. The source
  # stays busy until the last flagged page reports back; only then do we flash.
  def handle_info({:reextract_done, sid, index, outcome}, socket) do
    entries =
      Enum.map(socket.assigns.source_entries, fn e ->
        if e.source_id == sid, do: reload_entry(e), else: e
      end)

    remaining = Map.get(socket.assigns.reextracting, sid, 1) - 1

    reextracting =
      if remaining > 0,
        do: Map.put(socket.assigns.reextracting, sid, remaining),
        else: Map.delete(socket.assigns.reextracting, sid)

    socket = assign(socket, source_entries: entries, reextracting: reextracting)

    if remaining > 0 do
      {:noreply, socket}
    else
      {kind, msg} = reextract_flash(outcome, entries, sid, index)
      {:noreply, put_flash(socket, kind, msg)}
    end
  end

  @impl true
  def handle_info(:poll_cheat_status, socket) do
    game = socket.assigns.game

    if game do
      case CheatSheet.status(game.id) do
        "done" ->
          content = CheatSheet.stored_content(game.id)
          provider = CheatSheet.stored_provider(game.id)
          model = CheatSheet.stored_model(game.id)
          elapsed = CheatSheet.stored_elapsed(game.id)

          {:noreply,
           socket
           |> assign(
             cheat_status: nil,
             cheat_content: content,
             cheat_error: nil,
             cheat_provider: provider,
             cheat_model: model,
             cheat_elapsed: elapsed,
             cheat_started_at: nil
           )
           |> put_flash(
             :info,
             "Content generated! Review and edit below, then click Save Cheat Sheet."
           )}

        "error" ->
          error = CheatSheet.stored_error(game.id)

          {:noreply, assign(socket, cheat_status: nil, cheat_error: error)}

        status when status in ["compressing", "generating"] ->
          started = socket.assigns.cheat_started_at || CheatSheet.stored_started(game.id)
          stuck? = started && System.system_time(:second) - started > 600
          provider = CheatSheet.stored_provider(game.id)
          model = CheatSheet.stored_model(game.id)
          elapsed = started && System.system_time(:second) - started

          if stuck? do
            CheatSheet.clear(game.id)

            {:noreply,
             assign(socket,
               cheat_status: nil,
               cheat_error: "Generation timed out after 10 minutes. Try again."
             )}
          else
            Process.send_after(self(), :poll_cheat_status, 2000)

            {:noreply,
             assign(socket,
               cheat_status: status,
               cheat_provider: provider,
               cheat_model: model,
               cheat_elapsed: elapsed
             )}
          end

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:cheat_done, game_id}, socket) do
    if socket.assigns.game && socket.assigns.game.id == game_id do
      send(self(), :poll_cheat_status)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bgg_enriched, game_id, :ok}, socket) do
    game = if socket.assigns.game, do: Games.get_game!(game_id), else: nil

    # The cover image renders off @game_changeset.data, so rebuild the changeset
    # on the fresh game (carrying any unsaved form edits) — otherwise the new
    # image_url doesn't show until a manual page reload.
    changeset =
      if game do
        prior = (socket.assigns[:game_changeset] && socket.assigns.game_changeset.changes) || %{}
        Games.change_game(game, prior)
      else
        socket.assigns[:game_changeset]
      end

    # Offer to pull expansions only after a user-initiated refresh, for base
    # games (an expansion has none of its own) that aren't already syncing, and
    # only when BGG actually lists expansions for the game.
    prompt? =
      socket.assigns.bgg_refresh_pending and not is_nil(game) and
        not Games.expansion?(game.id) and not socket.assigns.exp_syncing and
        RuleMaven.BGG.expansion_link_count(game) > 0

    {:noreply,
     socket
     |> assign(
       generating: false,
       game: game,
       game_changeset: changeset,
       bgg_refresh_pending: false,
       expansion_prompt: prompt?
     )
     |> put_flash(:info, "Game info refreshed from BGG!")}
  end

  def handle_info({:bgg_enriched, _game_id, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, "Failed to refresh: #{reason}")}
  end

  def handle_info({:expansion_progress, _game_id, done, total}, socket) do
    {:noreply, assign(socket, exp_syncing: true, exp_sync_progress: "#{done}/#{total}")}
  end

  def handle_info({:expansion_sync_done, game_id}, socket) do
    game = socket.assigns.game && Games.get_game!(game_id)

    {:noreply,
     socket
     |> assign(
       exp_syncing: false,
       exp_sync_progress: nil,
       expansions: (game && Games.expansions_for(game)) || socket.assigns.expansions,
       cheat_expansions:
         (game && Games.expansions_with_documents(game)) || socket.assigns.cheat_expansions
     )
     |> put_flash(:info, "Expansions updated from BGG.")}
  end

  @impl true
  def handle_info({:theme_palette, game_id, :ok}, socket) do
    game = if socket.assigns.game, do: Games.get_game!(game_id), else: nil

    {:noreply,
     socket
     |> assign(regenerating_theme: false, game: game)
     |> put_flash(:info, "Game theme regenerated from cover art!")}
  end

  def handle_info({:theme_palette, _game_id, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(regenerating_theme: false)
     |> put_flash(:error, "Theme generation failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async(:search_bgg, {:ok, {cookies, result}}, socket) do
    require Logger

    case result do
      {:ok, results} ->
        Logger.debug("BGG search found #{length(results)} PDFs")

        search_error =
          if results == [], do: "No PDF rulebooks found on BGG files page"

        {:noreply,
         assign(socket,
           searching: false,
           bgg_results: results,
           search_error: search_error
         )}

      {:error, reason} ->
        Logger.error("BGG search error: #{reason}")

        reason =
          if String.contains?(reason, "403") && is_nil(cookies) do
            "BGG blocked the request. Set your BGG login credentials in Settings for access."
          else
            reason
          end

        {:noreply, assign(socket, searching: false, search_error: reason, bgg_results: [])}
    end
  end

  def handle_async(:search_bgg, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       searching: false,
       bgg_results: [],
       search_error: "BGG search failed: #{inspect(reason)}"
     )}
  end

  def handle_async(:bgg_search, {:ok, {query, result}}, socket) do
    case result do
      {:ok, results} ->
        {:noreply,
         assign(socket,
           bgg_searching: false,
           bgg_search_results: results,
           bgg_search_error: if(results == [], do: "No games found for '#{query}'")
         )}

      {:error, reason} ->
        {:noreply, assign(socket, bgg_searching: false, bgg_search_error: reason)}
    end
  end

  def handle_async(:bgg_search, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, bgg_searching: false, bgg_search_error: "Search failed: #{inspect(reason)}")}
  end

  def handle_async(:pull_bgg_info, {:ok, {changeset, result}}, socket) do
    case result do
      {:ok, info, _raw_xml} ->
        changeset = %{
          changeset
          | data: %{
              changeset.data
              | year_published: info.year_published,
                min_players: info.min_players,
                max_players: info.max_players,
                playing_time: info.playing_time,
                image_url: info.image_url
            },
            changes:
              Map.merge(changeset.changes, %{
                year_published: info.year_published,
                min_players: info.min_players,
                max_players: info.max_players,
                playing_time: info.playing_time,
                image_url: info.image_url
              })
        }

        {:noreply,
         socket
         |> assign(game_changeset: changeset)
         |> put_flash(:info, "Info pulled from BGG!")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_async(:pull_bgg_info, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  # Enqueue a durable, restart-survivable cleanup for one source at the auto
  # (escalation-loop) strength, and mirror the reset in the open form so
  # progress tracks from 0/total. `mode` is :raw (clean from the original
  # extraction) or :again (re-clean the current cleaned text). Locally we
  # blank the displayed cleaned layer either way so progress counts up live —
  # the :again input is read from the DB by the worker before this blanking
  # matters. No-op for an empty or already-cleaning source.
  defp start_cleanup(socket, sid, mode) do
    entry = Enum.find(socket.assigns.source_entries, &(&1.source_id == sid))

    if (entry && String.trim(entry.text || "") != "") and
         not Map.has_key?(socket.assigns.cleaning, sid) do
      {:ok, _job} = Games.enqueue_cleanup(Games.get_document!(sid), :auto, mode)

      entries =
        Enum.map(socket.assigns.source_entries, fn e ->
          if e.source_id == sid, do: reset_cleaned(e), else: e
        end)

      assign(socket,
        source_entries: entries,
        cleaning: Map.put(socket.assigns.cleaning, sid, {0, length(entry.pages)})
      )
    else
      socket
    end
  end

  # Single-page variant of start_cleanup/3: enqueue a durable clean of just
  # `index`. No layer reset — the page's cleaned text is swapped in place when
  # the worker broadcasts {:page_cleaned, ...}.
  defp start_page_cleanup(socket, sid, index) do
    entry = Enum.find(socket.assigns.source_entries, &(&1.source_id == sid))
    page = entry && Enum.find(entry.pages, &(&1[:index] == index))

    if (page && String.trim(page[:text] || "") != "") and
         not Map.has_key?(socket.assigns.cleaning, sid) do
      {:ok, _job} = Games.enqueue_cleanup_page(Games.get_document!(sid), index, :auto)
      assign(socket, cleaning: Map.put(socket.assigns.cleaning, sid, {0, 1}))
    else
      socket
    end
  end

  # Null a source's cleaned layer in the open form (mirrors a fresh re-clean in
  # the DB) so the progress indicator tracks from 0.
  defp reset_cleaned(entry) do
    pages = Enum.map(entry.pages, &Map.put(&1, :cleaned, nil))
    %{entry | pages: pages, text: Games.rebuild_full_text(pages)}
  end

  # Set one page's :cleaned (matched by physical index) and refresh full_text.
  defp put_page_cleaned(entry, idx, text) do
    pages =
      Enum.map(entry.pages, fn p ->
        if Map.get(p, :index) == idx, do: Map.put(p, :cleaned, text), else: p
      end)

    %{entry | pages: pages, text: Games.rebuild_full_text(pages)}
  end

  # Reload a source entry's pages from the DB (final persisted cleaned text).
  defp reload_entry(%{source_id: sid} = entry) when is_integer(sid) do
    doc = Games.get_document!(sid)
    %{entry | pages: doc_pages(doc), text: doc.full_text}
  end

  defp reload_entry(entry), do: entry

  # Mark a source busy for `n` in-flight re-extraction jobs. Per-page progress now
  # streams to the admin job panel (each page is its own run); the form only
  # tracks the busy count, which {:reextract_done} counts back down to zero.
  defp start_reextract(socket, sid, n) do
    assign(socket, reextracting: Map.put(socket.assigns.reextracting, sid, n))
  end

  # Honest re-extract feedback: the strong re-read can fail, or succeed but still
  # come back low-confidence (same flag, ~same text) — which reads as "nothing
  # changed". Tell the user which actually happened.
  defp reextract_flash(:ok, entries, sid, index) do
    page =
      entries
      |> Enum.find(&(&1.source_id == sid))
      |> case do
        nil -> nil
        entry -> Enum.find(entry.pages, &(&1.index == index))
      end

    if page && page[:needs_review] do
      {:info,
       "Re-extracted with the strongest model, but the page is still low-confidence. Edit it by hand if it's wrong."}
    else
      {:info, "Re-extracted the page — it's no longer flagged."}
    end
  end

  defp reextract_flash({:error, reason}, _entries, _sid, _index),
    do: {:error, "Re-extraction failed (#{reason}). The page is unchanged."}

  defp reextract_flash(:noop, _entries, _sid, _index),
    do: {:error, "Couldn't find that page to re-extract."}

  # Build the LiveView source-entry map (with first-class pages) from a Document.
  # Per-source extraction decision log: one row per page showing how/why it was
  # extracted (lane, decision, confidence, gate signals, critic outcome). Gate
  # and critic columns are blank for pages extracted before this was recorded or
  # where the signal doesn't apply (e.g. a clean text-layer page never cross-checks).
  attr :pages, :list, required: true

  def decision_log(assigns) do
    assigns = assign(assigns, :rows, Enum.filter(assigns.pages, &decided?/1))

    ~H"""
    <details :if={@rows != []} style="margin-top:0.6rem">
      <summary style="cursor:pointer;font-size:0.72rem;font-weight:600;color:var(--text-secondary);user-select:none">
        🧭 Extraction decision log ({length(@rows)} page{if length(@rows) == 1, do: "", else: "s"})
      </summary>
      <div style="overflow-x:auto;margin-top:0.4rem;border:1px solid var(--border-subtle);border-radius:0.4rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.7rem">
          <thead>
            <tr style="background:var(--bg-subtle);color:var(--text-secondary);text-align:left">
              <th style="padding:0.3rem 0.5rem;font-weight:600">Page</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600">Lane</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600">Decision</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600;text-align:right">Conf</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600;text-align:right">Agree</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600;text-align:right">Cov</th>
              <th style="padding:0.3rem 0.5rem;font-weight:600">Critic</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={p <- @rows}
              style="border-top:1px solid var(--border-subtle)"
            >
              <td style="padding:0.3rem 0.5rem;white-space:nowrap;color:var(--text-secondary)">
                {page_label(p)}
              </td>
              <td style="padding:0.3rem 0.5rem;white-space:nowrap;color:var(--text-secondary)">
                {p[:lane] || "—"}
              </td>
              <td style={"padding:0.3rem 0.5rem;white-space:nowrap;color:#{decision_color(p)}"}>
                {decision_label(p)}
              </td>
              <td style={"padding:0.3rem 0.5rem;text-align:right;color:#{conf_color(p[:confidence])}"}>
                {fmt_num(p[:confidence])}
              </td>
              <td style="padding:0.3rem 0.5rem;text-align:right;color:var(--text-muted)">
                {fmt_num(p[:gate_agreement])}
              </td>
              <td style="padding:0.3rem 0.5rem;text-align:right;color:var(--text-muted)">
                {fmt_num(p[:gate_coverage])}
              </td>
              <td style="padding:0.3rem 0.5rem;white-space:nowrap;color:var(--text-muted)">
                {critic_label(p)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  # A page has something to show when it carries any extraction provenance.
  defp decided?(p), do: p[:lane] != nil or p[:source] != nil

  defp page_label(p) do
    cond do
      p[:printed] -> "p.#{p[:printed]}"
      p[:sheet] -> "sheet #{p[:sheet]}"
      true -> "##{(p[:index] || 0) + 1}"
    end
  end

  defp decision_label(%{source: "text_layer"}), do: "clean text ✓"
  defp decision_label(%{source: "crosscheck"}), do: "two reads agree ✓"
  defp decision_label(%{source: "critic"}), do: "escalated → critic ✓"
  defp decision_label(%{source: "critic_residual"}), do: "escalated → residual ⚠"
  defp decision_label(%{source: "error"}), do: "extraction error ✗"
  defp decision_label(_), do: "—"

  defp decision_color(%{source: s}) when s in ["critic_residual", "error"], do: "var(--red)"
  defp decision_color(%{source: "critic"}), do: "var(--yellow)"
  defp decision_color(_), do: "var(--text)"

  defp critic_label(%{critic_rounds: r, residual_defects: d}) when is_integer(r) do
    "#{r} round#{if r == 1, do: "", else: "s"}, #{d || 0} residual"
  end

  defp critic_label(_), do: "—"

  defp conf_color(c) when is_float(c) and c < 0.6, do: "var(--red)"
  defp conf_color(c) when is_float(c), do: "var(--text)"
  defp conf_color(_), do: "var(--text-muted)"

  defp fmt_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt_num(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_num(_), do: "—"

  defp source_entry(s, i) do
    %{
      id: i,
      source_id: s.id,
      label: s.label,
      kind: s.kind,
      text: s.full_text,
      pages: doc_pages(s),
      pdf_path: s.pdf_path,
      html_path: s.html_path
    }
  end

  # Plain page maps for the form (text/cleaned/edited layers), from the doc's
  # embedded pages (or parsed from legacy full_text when not yet backfilled).
  defp doc_pages(s) do
    case s.pages do
      [_ | _] = ps ->
        Enum.map(ps, fn p ->
          %{
            index: p.index,
            sheet: p.sheet,
            printed: p.printed,
            text: p.text || "",
            cleaned: p.cleaned,
            confidence: p.confidence,
            needs_review: Games.page_needs_review?(p),
            # Decision-log detail for the per-source decision table.
            lane: Map.get(p, :lane),
            source: Map.get(p, :source),
            gate_agreement: Map.get(p, :gate_agreement),
            gate_coverage: Map.get(p, :gate_coverage),
            escalated: Map.get(p, :escalated),
            critic_rounds: Map.get(p, :critic_rounds),
            residual_defects: Map.get(p, :residual_defects)
          }
        end)

      _ ->
        Games.pages_from_full_text(s.full_text || "")
        |> Enum.map(&(&1 |> Map.put(:cleaned, nil) |> Map.put(:needs_review, false)))
    end
  end

  # Build the {source_id => {done, total}} map for sources whose cleanup is still
  # queued/running, derived from durable state: Oban job presence (survives a
  # server restart) plus the document's durable progress counter — so a refresh
  # mid-clean shows the same number the worker last persisted.
  defp seed_cleaning(entries) do
    for %{source_id: sid, pages: pages} <- entries,
        not is_nil(sid),
        Games.cleanup_running?(sid),
        into: %{} do
      {sid, {Games.cleaning_done(sid) || 0, length(pages)}}
    end
  end

  # Rebuild the {source_id => remaining_count} busy map for sources with in-flight
  # re-extraction jobs, from durable Oban job state — so a refresh mid-re-extract
  # still shows the "Re-extracting…" indicator with the right remaining count
  # (and the {:reextract_done} broadcasts still land, since mount re-subscribes).
  defp seed_reextracting(entries) do
    for %{source_id: sid} <- entries,
        not is_nil(sid),
        n = RuleMaven.Workers.ReextractPageWorker.active_count(sid),
        n > 0,
        into: %{},
        do: {sid, n}
  end

  defp parse_id(id_str) do
    case Integer.parse(to_string(id_str)) do
      {id, _} -> id
      _ -> id_str
    end
  end

  # Normalise a step delta string to -1 or 1 (anything else → nil).
  defp parse_delta("1"), do: 1
  defp parse_delta("-1"), do: -1
  defp parse_delta(_), do: nil

  # The Manage tab's currently-shown source id, falling back to the first source
  # when none is selected yet or the selection is stale (matches the template).
  defp current_inline_source_id(socket) do
    entries = socket.assigns.source_entries
    sel = socket.assigns.selected_source_id

    cond do
      Enum.any?(entries, &(&1.id == sel)) -> sel
      first = List.first(entries) -> first.id
      true -> nil
    end
  end

  defp resolve_bgg_cookies do
    bgg_user = Settings.get("bgg_user")
    bgg_pass = Settings.get("bgg_pass")

    if bgg_user && bgg_pass do
      case RuleMaven.BGG.login(bgg_user, bgg_pass) do
        {:ok, cookies} -> cookies
        _ -> nil
      end
    end
  end

  # Returns {:ok, socket} on success (flash + navigate queued) or
  # {:error, socket} with the invalid changeset assigned — the caller must not
  # ingest uploads or navigate on error.
  defp save_game(socket, nil, game_params, source_map) do
    case Games.create_game(game_params) do
      {:ok, game} ->
        Enum.each(source_map, fn {label, attrs} ->
          Games.create_rulebook_source(Map.merge(attrs, %{game_id: game.id, label: label}))
        end)

        {:ok,
         socket
         |> put_flash(:info, "Game created!")
         |> push_navigate(to: ~p"/games/#{game}/edit")}

      {:error, changeset} ->
        {:error,
         socket
         |> assign(game_changeset: changeset)
         |> put_flash(:error, "Couldn't save: #{changeset_error_summary(changeset)}")}
    end
  end

  defp save_game(socket, game, game_params, source_map) do
    case Games.update_game(game, game_params) do
      {:ok, game} ->
        existing = Games.list_rulebook_sources(game)

        existing
        |> Enum.filter(fn s -> not Map.has_key?(source_map, s.label) end)
        |> Enum.each(&Games.delete_rulebook_source/1)

        existing_by_label = Map.new(existing, &{&1.label, &1})

        Enum.each(source_map, fn {label, attrs} ->
          case existing_by_label do
            %{^label => doc} ->
              # Persist the page layers (original/cleaned/edited) + derived
              # full_text; leave pdf_path/metadata intact. update_document
              # re-chunks only when full_text actually changes.
              Games.update_document(doc, %{full_text: attrs.full_text, pages: attrs.pages})

            _ ->
              Games.create_rulebook_source(Map.merge(attrs, %{game_id: game.id, label: label}))
          end
        end)

        {:ok,
         socket
         |> put_flash(:info, "Game updated!")
         |> push_navigate(to: ~p"/games/#{game}/edit")}

      {:error, changeset} ->
        {:error,
         socket
         |> assign(game_changeset: changeset)
         |> put_flash(:error, "Couldn't save: #{changeset_error_summary(changeset)}")}
    end
  end

  # "name can't be blank; bgg_id is invalid" — human-readable changeset errors
  # for the save-failure flash.
  defp changeset_error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  # Shared page navigator for the inline editor and the expanded reader. Selects
  # a source's current page by Sheet number or printed Page number, with
  # prev/next steppers. `cur` is a 0-based position into `pages`.
  attr :id, :integer, required: true
  attr :pages, :list, required: true
  attr :cur, :integer, required: true

  defp page_nav(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.pages),
        step_style:
          "height:2.1rem;min-width:2.1rem;display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;font-size:1.25rem;line-height:1;padding:0 0.55rem;border-radius:0.4rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer",
        select_style:
          "height:2.1rem;min-width:8rem;box-sizing:border-box;border:1px solid var(--border);border-radius:0.4rem;padding:0 0.55rem;font-size:0.95rem;font-weight:600;background:var(--bg);color:var(--text);cursor:pointer"
      )

    ~H"""
    <div
      :if={@count > 0}
      style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap;margin-bottom:0.4rem"
    >
      <button
        type="button"
        phx-click="source_page_step"
        phx-value-id={@id}
        phx-value-delta="-1"
        disabled={@cur <= 0}
        title="Previous page (← or h)"
        style={@step_style}
      >‹</button>

      <label style="display:inline-flex;align-items:center;height:2.6rem;margin:0;gap:0.45rem;font-size:0.95rem;font-weight:600;color:var(--text-secondary)">
        Page
        <%!-- No <form> wrapper (would nest in the save form). Entry id is encoded
              in the name ("pagesel_<id>") and read from _target on change.
              List every page so unnumbered front/back matter stays reachable:
              numbered pages show their printed number; unnumbered ones show their
              sheet (otherwise an unnumbered sheet would vanish from the dropdown
              or falsely render as the first printed page). --%>
        <select name={"pagesel_#{@id}"} phx-change="set_source_page" style={@select_style}>
          <option :for={{p, i} <- Enum.with_index(@pages)} value={i} selected={i == @cur}>
            {if p.printed, do: "#{p.printed}", else: "Sheet #{p.sheet} (unnumbered)"}
          </option>
        </select>
      </label>

      <button
        type="button"
        phx-click="source_page_step"
        phx-value-id={@id}
        phx-value-delta="1"
        disabled={@cur >= @count - 1}
        title="Next page (→ or l)"
        style={@step_style}
      >›</button>
      <span style="font-size:1rem;font-weight:600;color:var(--text-muted);white-space:nowrap">{@cur +
        1} / {@count}</span>
    </div>
    """
  end

  # Warns when printed page-number detection failed for a source: every page
  # fell back to its physical sheet number, so citations read "Sheet N" instead
  # of the rulebook's real "Page N". Offers a manual fallback: enter the sheet
  # that carries printed "Page 1" and number the rest from there. Renders
  # nothing when at least one printed page was detected (or the source is empty).
  attr :id, :integer, required: true
  attr :pages, :list, required: true
  attr :page_one, :string, default: nil

  defp page_detection_badge(assigns) do
    assigns =
      assign(assigns,
        fell_back?: assigns.pages != [] and Enum.all?(assigns.pages, &is_nil(&1.printed))
      )

    ~H"""
    <div
      :if={@fell_back?}
      style="display:flex;flex-wrap:wrap;align-items:center;gap:0.4rem;margin-bottom:0.4rem"
    >
      <span
        title="No printed page numbers were detected in this rulebook (common for scanned/OCR PDFs). Answers will cite physical sheet numbers instead of the book's printed page numbers."
        style="display:inline-flex;align-items:center;gap:0.3rem;font-size:0.68rem;padding:0.15rem 0.5rem;border-radius:0.3rem;border:1px solid var(--amber-border, #d4a017);background:var(--amber-bg, rgba(212,160,23,0.12));color:var(--amber-text, #b8860b);white-space:nowrap"
      >
        ⚠ Couldn't detect page numbers — using sheet numbers
      </span>
      <%!-- No <form> wrapper (would nest in the save form). The entry id is
            encoded in the input name ("pageone_<id>") and read from _target on
            change; the button just triggers the numbering with the stored value. --%>
      <span style="display:inline-flex;align-items:center;gap:0.3rem;font-size:0.68rem;color:var(--text-muted)">
        Printed page 1 is on sheet
        <input
          type="number"
          min="1"
          max={length(@pages)}
          name={"pageone_#{@id}"}
          value={@page_one}
          phx-change="set_page_one_input"
          placeholder="#"
          style="width:3.2rem;height:1.6rem;box-sizing:border-box;border:1px solid var(--border);border-radius:0.3rem;padding:0 0.3rem;font-size:0.72rem;background:var(--bg);color:var(--text)"
        />
        <button
          type="button"
          phx-click="set_page_one"
          phx-value-id={@id}
          disabled={@page_one in [nil, ""]}
          title="Number every page from this sheet, then Save to apply."
          style="height:1.6rem;display:inline-flex;align-items:center;font-size:0.68rem;padding:0 0.55rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
        >Number pages</button>
      </span>
    </div>
    """
  end

  # Review badge: a per-source count of low-confidence pages and, when the current
  # page is one of them, a banner with a durable "re-extract one tier up" action.
  # Driven by the persisted gate confidence (page.needs_review). `busy` reflects a
  # re-extraction job already running for this source. Re-extract only offered for
  # saved sources (source_id) of PDF/image type (sheet render needed).
  attr :id, :integer, required: true
  attr :pages, :list, required: true
  attr :cur, :integer, required: true
  attr :can_reextract, :boolean, default: false
  attr :busy, :boolean, default: false

  # Re-extraction renders a single page, so it only applies to saved PDF/image
  # sources (native docx/xlsx/etc. have no page image — and never flag for review
  # anyway, since they carry no extraction confidence).
  defp reextractable_source?(%{source_id: sid, pdf_path: path})
       when is_integer(sid) and is_binary(path) do
    Path.extname(path) |> String.downcase() |> Kernel.in(~w(.pdf .png .jpg .jpeg .webp .gif))
  end

  defp reextractable_source?(_), do: false

  # Aggregate gate outcome across every source on the game. `graded` counts
  # pages that carried an extraction confidence (i.e. went through the gate —
  # native docx/xlsx pages have none); `flagged` counts the low-confidence ones
  # still needing review. graded > 0 && flagged == 0 → everything passed.
  defp confidence_summary(entries) do
    pages = Enum.flat_map(entries, & &1.pages)

    %{
      graded: Enum.count(pages, &is_number(&1[:confidence])),
      flagged: Enum.count(pages, & &1[:needs_review])
    }
  end

  # Green "all passed" / amber "N flagged" banner summarising the gate across all
  # rulebook sources. Silent when no page was graded (nothing to vouch for).
  defp confidence_banner(assigns) do
    assigns = assign(assigns, summary: confidence_summary(assigns.entries))

    ~H"""
    <div :if={@summary.graded > 0}>
      <span
        :if={@summary.flagged == 0}
        title="Every extracted page cleared the confidence gate (two reads agreed and the adversarial check found no residual defects)."
        style="display:inline-flex;align-items:center;gap:0.4rem;font-size:0.75rem;font-weight:600;padding:0.25rem 0.6rem;border-radius:0.3rem;border:1px solid var(--green-border, #2f9e44);background:var(--green-bg, rgba(47,158,68,0.12));color:var(--green-text, #2b8a3e)"
      >✓ All {@summary.graded} page(s) passed the confidence check</span>
      <span
        :if={@summary.flagged > 0}
        title="Some pages had low extraction confidence. Open them below to verify or re-extract."
        style="display:inline-flex;align-items:center;gap:0.4rem;font-size:0.75rem;font-weight:600;padding:0.25rem 0.6rem;border-radius:0.3rem;border:1px solid var(--amber-border, #d4a017);background:var(--amber-bg, rgba(212,160,23,0.12));color:var(--amber-text, #b8860b)"
      >⚠ {@summary.flagged} of {@summary.graded} page(s) flagged for review</span>
    </div>
    """
  end

  defp review_flag(assigns) do
    assigns =
      assign(assigns,
        flagged: Enum.count(assigns.pages, & &1[:needs_review]),
        cur_flagged?: match?(%{needs_review: true}, Enum.at(assigns.pages, assigns.cur))
      )

    ~H"""
    <div :if={@flagged > 0} style="margin-bottom:0.4rem">
      <div
        :if={@cur_flagged?}
        title="The extraction gate had low confidence in this page (two reads disagreed and the adversarial check left residual defects). Verify it against the source and fix the text if needed."
        style="display:inline-flex;flex-wrap:wrap;align-items:center;gap:0.5rem;font-size:0.7rem;padding:0.25rem 0.55rem;border-radius:0.3rem;border:1px solid var(--amber-border, #d4a017);background:var(--amber-bg, rgba(212,160,23,0.12));color:var(--amber-text, #b8860b)"
      >
        <span>⚠ Low-confidence extraction — verify or fix this page.</span>
        <button
          :if={@can_reextract}
          type="button"
          phx-click="reextract_page"
          phx-value-id={@id}
          phx-value-page={@cur}
          data-confirm="Re-extract this page with the stronger model? It overwrites the current page text and uses extra LLM credits."
          disabled={@busy}
          style="font-size:0.68rem;padding:0.1rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg);color:var(--text);cursor:pointer"
        >{if @busy, do: "Re-extracting…", else: "Re-extract (stronger model)"}</button>
      </div>
      <span
        :if={not @cur_flagged?}
        style="font-size:0.68rem;color:var(--text-muted)"
      >⚠ {@flagged} page(s) flagged for review — navigate to them to verify.</span>

      <%!-- Bulk action: re-extract every flagged page at once. Shown whichever
            page you're on, so you don't have to visit each one. --%>
      <div :if={@can_reextract and @flagged > 0} style="margin-top:0.4rem">
        <button
          type="button"
          phx-click="reextract_all"
          phx-value-id={@id}
          data-confirm={"Re-extract all #{@flagged} flagged page#{if @flagged == 1, do: "", else: "s"} with the stronger model? This overwrites their text and uses extra LLM credits."}
          disabled={@busy}
          style="font-size:0.68rem;padding:0.15rem 0.55rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
        >{if @busy,
          do: "Re-extracting…",
          else: "⟳ Re-extract all #{@flagged} flagged (stronger model)"}</button>
      </div>
    </div>
    """
  end

  @edit_tabs ~w(details rulebook manage cheatsheet danger)

  # Last edit tab for this game, remembered in localStorage and delivered via the
  # LiveSocket connect params as JSON {game_id => tab}. nil when absent/invalid.
  defp restore_edit_tab(socket, game_id) do
    with true <- connected?(socket),
         %{"edit_tab" => json} when is_binary(json) and json != "" <-
           get_connect_params(socket),
         {:ok, %{} = blob} <- Jason.decode(json),
         tab when tab in @edit_tabs <- Map.get(blob, to_string(game_id)) do
      tab
    else
      _ -> nil
    end
  end

  # Last page/sheet per source for this game, from localStorage as JSON
  # {game_id => {source_id => page}}. Keys come back as strings; convert to the
  # integer source ids the reader keys @source_page by. Empty on anything off.
  # Track the current page per source and mirror it to localStorage (via the
  # browser, keyed by game) so a refresh reopens the last page/sheet the user
  # was on. Restored in mount from the LiveSocket connect params.
  defp persist_source_page(socket, id, page) do
    sp = Map.put(socket.assigns.source_page, id, page)

    socket
    |> assign(source_page: sp)
    |> push_event("save_reader_page", %{
      game_id: socket.assigns.game.id,
      source_id: id,
      page: page
    })
  end

  defp restore_source_page(socket, game_id) do
    with true <- connected?(socket),
         %{"reader_pages" => json} when is_binary(json) and json != "" <-
           get_connect_params(socket),
         {:ok, %{} = blob} <- Jason.decode(json),
         %{} = game_map <- Map.get(blob, to_string(game_id)) do
      for {k, v} <- game_map, is_integer(v), into: %{}, do: {String.to_integer(k), v}
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # ── Page-layer (Original/Cleaned) helpers ──

  # The layer a source shows: explicit user choice, else the editable Cleaned
  # working copy (its content seeds from the original via layer_text/2). Before
  # cleanup has run there's no cleaned text to show, so force Original and ignore
  # any stale "cleaned" selection (the Cleaned tab is disabled in that state).
  defp editor_layer(entry, editor_tab) do
    if cleaned_available?(entry) do
      Map.get(editor_tab, entry.id) || "cleaned"
    else
      "original"
    end
  end

  # True once at least one page carries persisted cleaned text (cleanup has run).
  defp cleaned_available?(entry) do
    Enum.any?(entry.pages, &is_binary(&1[:cleaned]))
  end

  # Text shown for a page in a given layer. The Cleaned working copy is seeded
  # from the original text until it's auto-cleaned or hand-edited.
  defp layer_text(p, "original"), do: p.text || ""
  defp layer_text(p, "cleaned"), do: if(is_binary(p[:cleaned]), do: p.cleaned, else: p.text || "")

  # Cleaned is the editable working copy. Original is read-only, except for an
  # unsaved manual entry whose first content is its original.
  defp layer_editable?(_entry, "cleaned"), do: true
  defp layer_editable?(entry, "original"), do: is_nil(entry.source_id)
  defp layer_editable?(_entry, _), do: false

  defp layer_field("original"), do: "orig"
  defp layer_field(_), do: "clean"

  attr :id, :integer, required: true
  attr :current, :string, required: true
  attr :cleaned_available, :boolean, default: true

  defp layer_tabs(assigns) do
    ~H"""
    <div style="display:inline-flex;gap:0.25rem;margin-bottom:0.4rem">
      <button
        :for={tab <- ~w(original cleaned)}
        type="button"
        disabled={tab == "cleaned" and not @cleaned_available}
        title={
          if(tab == "cleaned" and not @cleaned_available,
            do: "Run cleanup first to view the cleaned text"
          )
        }
        phx-click="set_editor_tab"
        phx-value-id={@id}
        phx-value-tab={tab}
        style={"font-size:0.68rem;padding:0.15rem 0.55rem;border-radius:0.3rem;text-transform:capitalize;border:1px solid var(--border);#{layer_tab_style(tab, @current, @cleaned_available)}"}
      >{tab}</button>
    </div>
    """
  end

  # Disabled (grayed, not clickable) for the Cleaned tab before cleanup has run;
  # otherwise the usual active/inactive pill styling.
  defp layer_tab_style("cleaned", _current, false),
    do: "cursor:not-allowed;opacity:0.5;background:var(--bg-subtle);color:var(--text-muted)"

  defp layer_tab_style(tab, current, _available) do
    base = "cursor:pointer;"

    base <>
      if tab == current,
        do: "background:var(--accent);color:white",
        else: "background:var(--bg-subtle);color:var(--text-secondary)"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-form">
      <div
        :if={@expansion_prompt}
        style="position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;padding:1.5rem"
      >
        <div
          style="background:var(--bg-surface,#fff);border-radius:0.5rem;max-width:26rem;width:100%;padding:1.5rem;box-shadow:0 10px 40px rgba(0,0,0,0.3)"
          phx-click-away="dismiss_expansion_prompt"
          phx-window-keydown="dismiss_expansion_prompt"
          phx-key="Escape"
        >
          <h3 style="font-size:1.05rem;font-weight:700;margin:0 0 0.5rem">Pull expansions now?</h3>
          <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem;line-height:1.45">
            Info for <strong>{@game && @game.name}</strong> is refreshed. Want to find and link
            this game's expansions from BGG now? This runs in the background — you can keep editing.
          </p>
          <div style="display:flex;gap:0.5rem;justify-content:flex-end">
            <button
              type="button"
              phx-click="dismiss_expansion_prompt"
              style="background:none;border:1px solid var(--border);color:var(--text);padding:0.4rem 0.9rem;border-radius:0.375rem;font-size:0.8rem;font-weight:600;cursor:pointer"
            >
              Later
            </button>
            <button
              type="button"
              phx-click="pull_expansions"
              style="background:var(--accent);color:#fff;border:none;padding:0.4rem 0.9rem;border-radius:0.375rem;font-size:0.8rem;font-weight:600;cursor:pointer"
            >
              Pull expansions now
            </button>
          </div>
        </div>
      </div>

      <div class="mb-4 flex items-center justify-between">
        <.link navigate={~p"/"} class="back-link" style="margin-bottom:0">
          &larr; Back to games
        </.link>
        <div style="display:flex;align-items:center;gap:1rem">
          <.link
            :if={@game && bgg_synced?(@game)}
            href={~p"/games/#{@game}/prepare"}
            class="back-link"
            style="margin-bottom:0"
          >
            Prepare game &rarr;
          </.link>
          <.link
            :if={@game}
            navigate={~p"/games/#{@game}"}
            class="back-link"
            style="margin-bottom:0"
          >
            Ask questions &rarr;
          </.link>
        </div>
      </div>

      <h1 class="text-2xl font-bold mb-6">
        {if @game, do: "Edit #{@game.name}", else: "Add Game"}
        <%= if @game && @game.bgg_id do %>
          <button
            type="button"
            phx-click="refresh_bgg"
            disabled={@generating}
            style={"background:var(--accent);color:#fff;border:none;font-size:0.75rem;font-weight:600;margin-left:0.5rem;padding:0.35rem 0.85rem;border-radius:0.375rem;vertical-align:middle;cursor:#{if @generating, do: "default", else: "pointer"};opacity:#{if @generating, do: "0.6", else: "1"}"}
          >
            {if @generating, do: "⟳ Pulling…", else: "Pull from BGG"}
          </button>
        <% end %>
      </h1>

      <%!-- New game: simple form, no tabs --%>
      <%= if is_nil(@game) do %>
        <div>
          <%= if @game_changeset && @game_changeset.data.bgg_id do %>
            <div class="flex gap-3 items-center mb-6 p-3 border rounded-lg bg-gray-50">
              <%= if @game_changeset.data.image_url do %>
                <img
                  src={@game_changeset.data.image_url}
                  alt=""
                  style="width:80px;height:80px;object-fit:cover;border-radius:0.375rem;flex-shrink:0"
                />
              <% end %>
              <div>
                <p class="font-semibold">{@game_changeset.data.name}</p>
                <p class="text-xs text-gray-400 mt-0.5">BGG ID: {@game_changeset.data.bgg_id}</p>
              </div>
            </div>
          <% end %>

          <div class="border rounded-lg p-3 mb-4">
            <label class="block text-xs font-medium mb-1 text-gray-500">Find on BGG to auto-fill</label>
            <form phx-submit="bgg_search" class="flex gap-2">
              <input
                type="text"
                name="search"
                value={@bgg_search}
                placeholder="Search BGG by game name..."
                class="flex-1 border rounded px-3 py-2 text-sm"
                autocomplete="off"
              />
              <button
                type="submit"
                disabled={@bgg_searching}
                style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer;white-space:nowrap"
              >Search</button>
            </form>
            <%= if @bgg_searching do %>
              <p class="text-xs text-gray-400 mt-1">Searching...</p>
            <% end %>
            <%= if @bgg_search_error do %>
              <p class="text-xs text-red-500 mt-1">{@bgg_search_error}</p>
            <% end %>
            <%= if @bgg_search_results != [] do %>
              <div class="mt-2 border rounded max-h-40 overflow-y-auto">
                <%= for result <- @bgg_search_results |> Enum.take(10) do %>
                  <button
                    type="button"
                    phx-click="bgg_select"
                    phx-value-id={result.bgg_id}
                    phx-value-name={result.name}
                    class="w-full text-left px-3 py-1.5 text-sm hover:bg-gray-50 border-b last:border-b-0"
                  >
                    <span class="font-medium">{result.name}</span>
                    <span :if={result.year} class="text-gray-400 ml-2">({result.year})</span>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>

          <.form for={@game_changeset} id="new-game-form" phx-submit="save" class="mt-2">
            <div style="margin-bottom:1rem">
              <label for="new_game_name" class="block text-sm font-medium mb-1">Name</label>
              <input
                type="text"
                name="game[name]"
                id="new_game_name"
                value={@game_changeset && @game_changeset.data.name}
                class="w-full border rounded px-3 py-2"
                placeholder="Game name"
                required
              />
            </div>
            <div style="margin-bottom:1rem">
              <label for="new_game_category" class="block text-sm font-medium mb-1">Category</label>
              <select
                name="game[category]"
                id="new_game_category"
                class="w-full border rounded px-3 py-2"
              >
                <%= for {label, value} <- RuleMaven.Games.Category.options() do %>
                  <option
                    value={value}
                    selected={
                      ((@game_changeset && @game_changeset.data.category) || "board_game") == value
                    }
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>
            <div style="margin-bottom:1.25rem">
              <label for="new_game_bgg_id" class="block text-sm font-medium mb-1">BGG ID
              <span class="text-gray-400">(optional)</span></label>
              <input
                type="number"
                name="game[bgg_id]"
                id="new_game_bgg_id"
                value={@game_changeset && @game_changeset.data.bgg_id}
                class="w-full border rounded px-3 py-2"
              />
            </div>
            <.button variant="primary" type="submit">Create Game</.button>
          </.form>
        </div>
      <% end %>

      <%!-- Edit mode, not yet synced with BGG: gate the whole editor behind a
            sync prompt. A catalog game only has name/year/rank until BGG is
            pulled (image, players, play time), and the rest of the editor
            assumes that data exists. --%>
      <div
        :if={@game && not bgg_synced?(@game) && not @bgg_gate_bypassed}
        style="text-align:center;max-width:34rem;margin:2rem auto;padding:2.5rem 2rem;border:1px dashed var(--border-strong);border-radius:0.75rem;background:var(--bg-surface)"
      >
        <div style="font-size:2.5rem;margin-bottom:0.5rem">🔗</div>
        <h2 style="font-size:1.25rem;font-weight:700;margin:0 0 0.5rem">
          Pull from BoardGameGeek first
        </h2>
        <p style="font-size:0.85rem;color:var(--text-muted);line-height:1.55;margin:0 auto 1.5rem;max-width:26rem">
          This game only has its catalog basics so far. Pull its details from
          BoardGameGeek — cover image, player count, play time — before adding
          rulebooks or cheat sheets.
        </p>
        <%= if @game.bgg_id do %>
          <button
            type="button"
            phx-click="refresh_bgg"
            disabled={@generating}
            style={"background:var(--accent);color:#fff;border:none;padding:0.6rem 1.5rem;border-radius:0.5rem;font-weight:700;font-size:0.9rem;cursor:#{if @generating, do: "default", else: "pointer"};opacity:#{if @generating, do: "0.6", else: "1"}"}
          >
            {if @generating, do: "⟳ Pulling from BGG…", else: "Pull from BGG"}
          </button>
          <p style="font-size:0.72rem;color:var(--text-muted);margin:0.85rem 0 0">
            BGG ID {@game.bgg_id} · runs in the background; this page updates when it's done.
          </p>
        <% else %>
          <p style="font-size:0.82rem;color:var(--red);margin:0">
            This game has no BGG ID linked, so it can't be pulled. Set a BGG ID in
            the database first.
          </p>
        <% end %>

        <%!-- Escape hatch: BGG may be down or the game may have no usable data.
              Let the admin into the editor anyway. --%>
        <div style="margin-top:1.5rem;padding-top:1.25rem;border-top:1px solid var(--border)">
          <button
            type="button"
            phx-click="bypass_bgg_gate"
            style="background:none;border:none;color:var(--text-muted);font-size:0.78rem;font-weight:600;text-decoration:underline;cursor:pointer"
          >
            Skip and edit anyway
          </button>
          <p style="font-size:0.7rem;color:var(--text-muted);margin:0.4rem 0 0">
            Use this if the pull keeps failing. You can fill in details by hand.
          </p>
        </div>
      </div>

      <div :if={@game && (bgg_synced?(@game) or @bgg_gate_bypassed)}>
        <!-- BGG info bar (edit mode) -->
        <%= if @game_changeset && @game_changeset.data.bgg_id do %>
          <div class="flex gap-3 items-center mb-4 p-3 border rounded-lg bg-gray-50">
            <%= if @game_changeset.data.image_url do %>
              <img
                src={@game_changeset.data.image_url}
                alt=""
                style="width:80px;height:80px;object-fit:cover;border-radius:0.375rem;flex-shrink:0"
              />
            <% end %>
            <div>
              <p class="font-semibold">{@game_changeset.data.name}</p>
              <p class="text-xs text-gray-500">
                <%= if @game_changeset.data.year_published do %>
                  {@game_changeset.data.year_published}
                <% end %>
                <%= if @game_changeset.data.min_players do %>
                  &middot; {@game_changeset.data.min_players}-{@game_changeset.data.max_players}p
                <% end %>
                <%= if @game_changeset.data.playing_time do %>
                  &middot; ~{@game_changeset.data.playing_time}m
                <% end %>
              </p>
              <p class="text-xs text-gray-400 mt-0.5">
                <.link
                  href={"https://boardgamegeek.com/boardgame/#{@game_changeset.data.bgg_id}"}
                  target="_blank"
                  rel="noopener"
                  class="text-blue-500 hover:underline"
                >BGG ID: {@game_changeset.data.bgg_id}</.link>
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Tabs (below the game image panel, above the form) --%>
        <div style="display:flex;border-bottom:1px solid var(--border);margin-bottom:1rem">
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="details"
            style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "details", do: "var(--blue)", else: "transparent"};color:#{if @tab == "details", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "details", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}
          >
            Details
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="rulebook"
            style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "rulebook", do: "var(--blue)", else: "transparent"};color:#{if @tab == "rulebook", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "rulebook", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}
          >
            Upload Rulebook
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="manage"
            style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "manage", do: "var(--blue)", else: "transparent"};color:#{if @tab == "manage", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "manage", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}
          >
            Manage Rulebooks
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="cheatsheet"
            style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "cheatsheet", do: "var(--blue)", else: "transparent"};color:#{if @tab == "cheatsheet", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "cheatsheet", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}
          >
            Cheatsheet
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="danger"
            style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "danger", do: "var(--blue)", else: "transparent"};color:#{if @tab == "danger", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "danger", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}
          >
            Danger
          </button>
        </div>

        <%!-- Download from URL: separate form (can't nest inside save form),
              shown above the Upload PDF on the Upload Rulebook tab. --%>
        <div :if={@tab == "rulebook"} class="border rounded-lg p-4 mb-4">
          <h2 class="text-base font-semibold mb-3">Download Rulebook from URL</h2>
          <div class="flex gap-2 mb-3">
            <button
              type="button"
              phx-click="find_download"
              disabled={@downloading}
              style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
            >Find &amp; Download</button>
            <%= if @game.bgg_id do %>
              <button
                type="button"
                phx-click="search_bgg"
                disabled={@searching}
                style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
              >{if @searching, do: "Searching BGG...", else: "Find on BGG"}</button>
            <% end %>
          </div>
          <%= if @game.bgg_id do %>
            <%= if @search_error do %>
              <p class="text-sm text-red-500 mb-2">{@search_error}</p>
            <% end %>
            <%= if @bgg_results != [] do %>
              <div class="border rounded p-2 mb-3 max-h-48 overflow-y-auto space-y-1">
                <%= for result <- @bgg_results do %>
                  <div class="flex items-center justify-between text-xs p-1 hover:bg-gray-50 rounded">
                    <span class="truncate">{result.label}</span>
                    <button
                      type="button"
                      phx-click="search_download"
                      phx-value-url={result.url}
                      phx-value-label={result.label}
                      disabled={@downloading}
                      style="color:var(--accent);border:none;background:none;font-size:0.75rem;font-weight:600;cursor:pointer;white-space:nowrap;margin-left:0.5rem"
                    >Download</button>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
          <form phx-submit="download">
            <div style="margin-bottom:0.5rem">
              <label class="block text-xs font-medium mb-1 text-gray-500">PDF URL</label>
              <input
                type="text"
                name="url"
                value={@download_url}
                placeholder="https://example.com/rulebook.pdf"
                class="w-full border rounded px-3 py-2 text-sm"
                disabled={@downloading}
              />
            </div>
            <div style="margin-bottom:0.5rem">
              <label class="block text-xs font-medium mb-1 text-gray-500">Label (optional)</label>
              <input
                type="text"
                name="label"
                value={@download_label}
                placeholder="e.g. Core Rulebook"
                class="w-full border rounded px-3 py-2 text-sm"
                disabled={@downloading}
              />
            </div>
            <button
              type="submit"
              disabled={@downloading}
              style="background:var(--accent);color:white;border:none;padding:0.4rem 0.875rem;border-radius:0.375rem;font-weight:600;font-size:0.875rem;cursor:pointer"
            >{if @downloading, do: "Downloading...", else: "Download"}</button>
          </form>
          <%= if @downloading do %>
            <div style="display:flex;align-items:center;gap:0.6rem;margin-top:0.6rem;font-size:0.8rem;color:var(--text-secondary)">
              <span style="display:inline-block;width:0.9rem;height:0.9rem;border:2px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:rm-spin 0.7s linear infinite"></span>
              <span>{@download_stage || "Downloading…"}</span>
              <button
                type="button"
                phx-click="cancel_download"
                style="margin-left:auto;font-size:0.72rem;padding:0.15rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
              >Cancel</button>
            </div>
            <style>
              @keyframes rm-spin { to { transform: rotate(360deg); } }
            </style>
          <% end %>
          <%= if @download_ok do %>
            <p class="text-sm mt-2" style="color:var(--green)">
              Downloaded!
              <.link href={"/#{@download_ok}"} target="_blank" class="underline font-semibold">View PDF</.link>
              or go to <.link navigate={~p"/games/#{@game}"} class="underline font-semibold">Ask page</.link>.
            </p>
          <% end %>
          <%= if @download_error do %>
            <p class="text-sm text-red-500 mt-2">{@download_error}</p>
          <% end %>
        </div>

        <.form
          for={@game_changeset}
          id="game-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6"
          style="max-width:56rem"
        >
          <%!-- Details tab --%>
          <div style={if @tab == "details", do: "display:block", else: "display:none"}>
            <div style="margin-bottom:1.25rem">
              <label for="game_name" class="block text-sm font-medium mb-1">Name</label>
              <input
                type="text"
                name="game[name]"
                id="game_name"
                value={@game_changeset.data.name}
                class="w-full border rounded px-3 py-2"
                required
              />
            </div>
            <div style="margin-bottom:1.25rem">
              <label for="game_category" class="block text-sm font-medium mb-1">Category</label>
              <select name="game[category]" id="game_category" class="w-full border rounded px-3 py-2">
                <%= for {label, value} <- RuleMaven.Games.Category.options() do %>
                  <option
                    value={value}
                    selected={(@game_changeset.data.category || "board_game") == value}
                  >
                    {label}
                  </option>
                <% end %>
              </select>
            </div>
            <div style="margin-bottom:1.25rem">
              <label for="game_bgg_id" class="block text-sm font-medium mb-1">BGG ID
              <span class="text-gray-400">(optional, board/card games)</span></label>
              <input
                type="number"
                name="game[bgg_id]"
                id="game_bgg_id"
                value={@game_changeset.data.bgg_id}
                class="w-full border rounded px-3 py-2"
              />
            </div>

            <%= if @game do %>
              <div style="margin-bottom:1.25rem">
                <label class="block text-sm font-medium mb-1">
                  Base Game
                  <span class="text-gray-400">(optional — set if this is an expansion)</span>
                </label>

                <%= if @parent_selected_id do %>
                  <div class="flex items-center gap-2 mb-2">
                    <span style="font-size:0.8rem">
                      Expansion of <strong>{@parent_selected_name}</strong>
                    </span>
                    <button
                      type="button"
                      phx-click="clear_parent"
                      data-confirm="Remove this game's expansion link to its parent?"
                      style="font-size:0.7rem;color:var(--red);background:none;border:none;cursor:pointer;font-weight:600"
                    >Clear</button>
                  </div>
                <% end %>

                <%= if @extra_bases != [] do %>
                  <div style="font-size:0.72rem;color:var(--text-muted);margin-bottom:0.5rem">
                    Also linked to: {Enum.map_join(@extra_bases, ", ", & &1.name)}
                  </div>
                <% end %>

                <input
                  type="text"
                  name="parent_query"
                  value={@parent_query}
                  autocomplete="off"
                  phx-keyup="search_parent"
                  phx-debounce="250"
                  placeholder="Search for a base game…"
                  class="w-full border rounded px-3 py-2 text-sm"
                />

                <%= if @parent_results != [] do %>
                  <div class="border rounded mt-1" style="max-height:12rem;overflow:auto">
                    <%= for base <- @parent_results do %>
                      <button
                        type="button"
                        phx-click="select_parent"
                        phx-value-id={base.id}
                        phx-value-name={base.name}
                        class="block w-full text-left px-3 py-1.5 text-sm"
                        style="background:none;border:none;cursor:pointer"
                      >{base.name}</button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div :if={@game} style="margin-bottom:1.25rem">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;margin-bottom:0.5rem">
                <h3 class="text-sm font-semibold" style="margin:0">Expansions of this game</h3>
                <button
                  type="button"
                  phx-click="pull_expansions"
                  disabled={@exp_syncing}
                  style={"background:var(--accent);color:#fff;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-size:0.72rem;font-weight:600;white-space:nowrap;cursor:#{if @exp_syncing, do: "default", else: "pointer"};opacity:#{if @exp_syncing, do: "0.6", else: "1"}"}
                >
                  {if @exp_syncing, do: "⟳ Pulling…", else: "Pull expansions from BGG"}
                </button>
              </div>

              <p
                :if={@exp_syncing}
                style="font-size:0.72rem;color:var(--text-muted);margin:0 0 0.5rem"
              >
                Finding and refreshing expansions from BGG{if @exp_sync_progress,
                  do: " — #{@exp_sync_progress}",
                  else: "…"}
              </p>

              <%= if length(@expansions) > 0 do %>
                <div class="space-y-1">
                  <%= for exp <- @expansions do %>
                    <div class="flex items-center justify-between border rounded px-3 py-1.5 text-sm">
                      <.link
                        navigate={~p"/games/#{exp}/edit"}
                        class="text-blue-600 hover:underline"
                      >{exp.name}</.link>
                      <button
                        type="button"
                        phx-click="unlink_expansion"
                        phx-value-id={exp.id}
                        data-confirm={"Unlink “#{exp.name}” from this game?"}
                        class="text-xs"
                        style="color:var(--red);background:none;border:none;cursor:pointer;font-weight:600"
                      >Unlink</button>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p :if={not @exp_syncing} style="font-size:0.75rem;color:var(--text-muted);margin:0">
                  No expansions linked yet. Pull from BGG to find and link this game's expansions
                  (they must already exist in the catalog).
                </p>
              <% end %>
            </div>
          </div>

          <%!-- Rulebooks tab --%>
          <div style={if @tab == "rulebook", do: "display:block", else: "display:none"}>
            <%!-- Upload PDF (inside .form so live_file_input hook attaches correctly) --%>
            <div class="border rounded-lg p-4 mb-4">
              <h2 class="text-base font-semibold mb-2">Upload PDF</h2>
              <div class="border-2 border-dashed border-gray-300 rounded-lg p-4 text-center">
                <.live_file_input upload={@uploads.rulebook_pdfs} class="block mx-auto text-sm" />
                <%= for entry <- @uploads.rulebook_pdfs.entries do %>
                  <div style="margin-top:0.5rem">
                    <div style="display:flex;justify-content:space-between;font-size:0.75rem;color:var(--text-secondary);margin-bottom:0.2rem">
                      <span>{entry.client_name}</span>
                      <span>{entry.progress}%</span>
                    </div>
                    <div style="height:4px;background:var(--border);border-radius:2px;overflow:hidden">
                      <div style={"height:100%;background:var(--blue);border-radius:2px;width:#{entry.progress}%;transition:width 0.2s"}>
                      </div>
                    </div>
                    <%= for err <- upload_errors(@uploads.rulebook_pdfs, entry) do %>
                      <p class="text-xs text-red-500 mt-1">{err}</p>
                    <% end %>
                  </div>
                <% end %>
                <%= for err <- upload_errors(@uploads.rulebook_pdfs) do %>
                  <p class="text-xs text-red-500 mt-1">{err}</p>
                <% end %>
              </div>
              <% pdf_btn_disabled = @uploads.rulebook_pdfs.entries == [] || @uploading_pdfs %>
              <button
                type="button"
                phx-click="process_uploads"
                disabled={pdf_btn_disabled}
                style={"margin-top:0.5rem;background:var(--accent);color:white;border:none;padding:0.4rem 0.875rem;border-radius:0.375rem;font-weight:600;font-size:0.875rem;cursor:pointer;opacity:#{if pdf_btn_disabled, do: 0.5, else: 1}"}
              >{if @uploading_pdfs, do: "Processing…", else: "Upload"}</button>
            </div>
          </div>

          <%!-- Manage Rulebooks tab --%>
          <div style={if @tab == "manage", do: "display:block", else: "display:none"}>
            <div class="space-y-4">
              <div style="display:flex;align-items:center;gap:0.75rem;flex-wrap:wrap">
                <h2 class="text-lg font-semibold">Rulebook Sources</h2>
                <.confidence_banner :if={@source_entries != []} entries={@source_entries} />
              </div>
              <div
                :if={@uploading_pdfs}
                style="display:flex;align-items:center;gap:0.6rem;padding:0.6rem 0.85rem;border:1px solid var(--blue);background:rgba(59,130,246,0.08);border-radius:0.4rem;font-size:0.82rem;color:var(--text-secondary)"
              >
                <span style="display:inline-block;width:0.9rem;height:0.9rem;border:2px solid var(--border);border-top-color:var(--blue);border-radius:50%;animation:rm-spin 0.7s linear infinite"></span>
                <span>{@download_stage || "Extracting rulebook…"}
                <span style="color:var(--text-muted)">— scanned PDFs run OCR in the background and can take a few minutes.</span></span>
                <button
                  type="button"
                  phx-click="cancel_download"
                  style="margin-left:auto;font-size:0.72rem;padding:0.15rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                >Cancel</button>
              </div>
              <style>
                @keyframes rm-spin { to { transform: rotate(360deg); } }
              </style>
              <p :if={@source_entries == []} style="color:var(--text-muted);font-size:0.85rem">
                No rulebook sources yet. Add one from the
                <button
                  type="button"
                  phx-click="switch_tab"
                  phx-value-tab="rulebook"
                  style="color:var(--blue);background:none;border:none;padding:0;font:inherit;cursor:pointer;text-decoration:underline"
                >Upload Rulebook</button>
                tab.
              </p>
              <%= if @source_entries != [] do %>
                <% entry =
                  Enum.find(@source_entries, &(&1.id == @selected_source_id)) ||
                    List.first(@source_entries) %>
                <%!-- One source at a time: pick which with the dropdown, or press
                      j / k to step through them (the editor is the same either
                      way). Hidden when there's only one source. --%>
                <div
                  :if={length(@source_entries) > 1}
                  style="display:flex;align-items:center;gap:0.5rem;margin-bottom:0.6rem;flex-wrap:wrap"
                >
                  <label style="font-size:0.8rem;font-weight:600;color:var(--text-secondary)">
                    Rulebook source
                  </label>
                  <select
                    name="inline_source"
                    phx-change="select_inline_source"
                    style="height:2.4rem;min-width:12rem;box-sizing:border-box;border:1px solid var(--border);border-radius:0.4rem;padding:0 0.6rem;font-size:0.95rem;font-weight:600;background:var(--bg);color:var(--text);cursor:pointer"
                  >
                    <option
                      :for={s <- @source_entries}
                      value={s.id}
                      selected={s.id == entry.id}
                    >
                      {if String.trim(s.label) != "", do: s.label, else: "Untitled source"} · {Document.kind_label(
                        s[:kind] || "rulebook"
                      )}
                    </option>
                  </select>
                  <span style="font-size:0.72rem;color:var(--text-muted)">
                    {Enum.find_index(@source_entries, &(&1.id == entry.id)) + 1} / {length(
                      @source_entries
                    )} · press j / k to switch
                  </span>
                </div>
                <div
                  id={"inline-reader-#{entry.id}"}
                  phx-hook="ReaderKeys"
                  data-reader-id={entry.id}
                  class="border rounded p-4"
                >
                  <div class="flex gap-2 items-end mb-2">
                    <div class="flex-1">
                      <label class="block text-sm font-medium mb-1">Label</label>
                      <input
                        type="text"
                        name={"label_#{entry.id}"}
                        value={entry.label}
                        placeholder="e.g. Core Rulebook"
                        class="w-full border rounded px-3 py-2"
                      />
                      <div style="display:flex;align-items:center;gap:0.5rem;margin-top:0.4rem">
                        <select
                          name={"kind_#{entry.id}"}
                          phx-change="set_kind"
                          style="font-size:0.75rem;padding:0.15rem 0.4rem;border:1px solid var(--border);border-radius:0.3rem;background:var(--bg);color:var(--text);cursor:pointer"
                        >
                          <option
                            :for={k <- Document.kinds()}
                            value={k}
                            selected={(entry[:kind] || "rulebook") == k}
                          >
                            {Document.kind_label(k)}
                          </option>
                        </select>
                        <span style="font-size:0.68rem;font-weight:600;padding:0.1rem 0.4rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary)">
                          {Document.kind_label(entry[:kind] || "rulebook")}
                        </span>
                      </div>
                    </div>
                    <div class="flex gap-1 items-center">
                      <button
                        :if={length(@source_entries) > 1}
                        type="button"
                        phx-click="remove_source"
                        phx-value-id={entry.id}
                        data-confirm="Remove this rulebook source?"
                        class="btn-remove-source"
                      >✕</button>
                      <button
                        :if={entry[:source_id] && @confirm_delete_source_id != entry.source_id}
                        type="button"
                        phx-click="delete_source"
                        phx-value-source_id={entry.source_id}
                        style="color:var(--red);background:none;border:none;font-size:0.75rem;cursor:pointer;white-space:nowrap"
                      >Delete</button>
                      <%= if entry[:source_id] && @confirm_delete_source_id == entry.source_id do %>
                        <span style="font-size:0.65rem;color:var(--red)">Sure?</span>
                        <button
                          type="button"
                          phx-click="confirm_delete_source"
                          phx-value-source_id={entry.source_id}
                          style="color:#fff;background:var(--red);border:none;font-size:0.6rem;cursor:pointer;padding:0.1rem 0.3rem;border-radius:0.2rem"
                        >Yes</button>
                        <button
                          type="button"
                          phx-click="cancel_delete_source"
                          style="color:var(--text-muted);background:none;border:none;font-size:0.6rem;cursor:pointer"
                        >No</button>
                      <% end %>
                    </div>
                  </div>

                  <label class="block text-sm font-medium mb-1">Text</label>
                  <% page_count = length(entry.pages) %>
                  <% cur =
                    @source_page |> Map.get(entry.id, 0) |> max(0) |> min(max(page_count - 1, 0)) %>
                  <% cur_page = Enum.at(entry.pages, cur) %>
                  <% layer = editor_layer(entry, @editor_tab) %>
                  <% reext_remaining = Map.get(@reextracting, entry.source_id, 0) %>
                  <% regenerating? = reext_remaining > 0 %>
                  <% editable =
                    layer_editable?(entry, layer) and @cleaning[entry.source_id] == nil and
                      not regenerating? %>
                  <.layer_tabs
                    id={entry.id}
                    current={layer}
                    cleaned_available={cleaned_available?(entry)}
                  />
                  <.page_nav id={entry.id} pages={entry.pages} cur={cur} />
                  <.page_detection_badge
                    id={entry.id}
                    pages={entry.pages}
                    page_one={@page_one_input[entry.id]}
                  />
                  <.review_flag
                    id={entry.id}
                    pages={entry.pages}
                    cur={cur}
                    can_reextract={reextractable_source?(entry)}
                    busy={regenerating?}
                  />
                  <%!-- Live re-extraction progress, streamed from the worker.
                        Editing is locked while it runs (the worker overwrites the
                        page on finish), so show why. --%>
                  <div
                    :if={regenerating?}
                    style="display:flex;align-items:center;gap:0.5rem;margin-bottom:0.4rem;font-size:0.72rem;color:var(--text-secondary)"
                  >
                    <span style="display:inline-block;width:0.8rem;height:0.8rem;border:2px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:rm-spin 0.7s linear infinite"></span>
                    <span>
                      Re-extracting {if reext_remaining > 1,
                        do: "#{reext_remaining} pages",
                        else: "this page"} — editing locked until {if reext_remaining > 1,
                        do: "they finish",
                        else: "it finishes"}.
                    </span>
                    <style>
                      @keyframes rm-spin { to { transform: rotate(360deg); } }
                    </style>
                  </div>
                  <%!-- Edits feed socket state via edit_page (layer encoded in the
                        name), so this stays in sync with the expanded reader. --%>
                  <textarea
                    :if={cur_page}
                    name={"pg_#{entry.id}_#{cur}_#{layer_field(layer)}"}
                    phx-change="edit_page"
                    phx-debounce="250"
                    rows="18"
                    class="w-full border rounded px-3 py-2 font-mono text-sm"
                    style={"resize:vertical;line-height:1.5#{if not editable, do: ";opacity:0.7;background:var(--bg-subtle)"}"}
                    placeholder="Paste rulebook text here..."
                    readonly={not editable}
                  ><%= layer_text(cur_page, layer) %></textarea>

                  <div class="mt-2 flex gap-3 items-center flex-wrap">
                    <% cleaning? = @cleaning[entry.source_id] != nil %>
                    <% has_cleaned = Enum.any?(entry.pages, &is_binary(&1[:cleaned])) %>
                    <% cur_cleaned = cur_page && is_binary(cur_page[:cleaned]) %>
                    <%!-- Cleans only the page shown above; whole-document
                          cleanup keeps its own buttons below. --%>
                    <button
                      type="button"
                      phx-click="cleanup_page"
                      phx-value-id={entry.id}
                      phx-value-page={(cur_page && cur_page[:index]) || cur}
                      data-confirm={
                        if cur_cleaned,
                          do:
                            "Discard this page's cleaned text and re-clean it from the original extraction? This can't be undone.",
                          else: nil
                      }
                      title={
                        if cur_cleaned,
                          do:
                            "Discard this page's cleaned text and clean it again from the original extraction.",
                          else: "Cleans this page — strength auto-adjusts per page"
                      }
                      disabled={
                        cleaning? || cur_page == nil ||
                          String.trim(cur_page[:text] || "") == ""
                      }
                      style="font-size:0.72rem;padding:0.2rem 0.6rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                    >
                      <%= case @cleaning[entry.source_id] do %>
                        <% nil -> %>
                          {if cur_cleaned, do: "✨ Re-clean page", else: "✨ Clean page"}
                        <% {d, t} when t > 1 -> %>
                          Cleaning {d}/{t}…
                        <% _ -> %>
                          Cleaning…
                      <% end %>
                    </button>
                    <button
                      type="button"
                      phx-click="cleanup_source"
                      phx-value-id={entry.id}
                      data-confirm={
                        if has_cleaned,
                          do:
                            "Discard the existing cleaned text and re-clean every page from the original extraction? This can't be undone.",
                          else: nil
                      }
                      title={
                        if has_cleaned,
                          do:
                            "Discard the existing cleaned text and clean every page again from the original extraction.",
                          else: "Clean up the whole rulebook's extracted text."
                      }
                      disabled={cleaning? || String.trim(entry.text || "") == ""}
                      style="font-size:0.72rem;padding:0.2rem 0.6rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                    >
                      {if has_cleaned, do: "✨ Wipe & clean all", else: "✨ Clean all"}
                    </button>
                    <button
                      :if={has_cleaned}
                      type="button"
                      phx-click="reclean_source"
                      phx-value-id={entry.id}
                      data-confirm="Run another cleanup pass over the cleaned text? This rewrites it and can't be undone."
                      title="Run another cleanup pass over the already-cleaned text to catch leftover junk."
                      disabled={cleaning? || String.trim(entry.text || "") == ""}
                      style="font-size:0.72rem;padding:0.2rem 0.6rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                    >↻ Clean again</button>
                    <button
                      type="button"
                      phx-click="expand_source"
                      phx-value-id={entry.id}
                      disabled={String.trim(entry.text || "") == ""}
                      title="Open the full-screen reader (press f to toggle; f again or Esc closes it)"
                      style="font-size:0.72rem;padding:0.2rem 0.6rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                    >⤢ Expand reader (f)</button>
                    <%!-- No raw-PDF link: rulebooks may be copyrighted, so we
                          don't offer the original file for download. The HTML is
                          our extracted text (admin view only). --%>
                    <%= if entry[:source_id] && entry[:html_path] do %>
                      <.link
                        href={~p"/rulebooks/#{RuleMaven.Hashid.encode(entry.source_id)}/html"}
                        target="_blank"
                        class="action-link"
                      >View as HTML</.link>
                      <button
                        type="button"
                        phx-click="regenerate_html"
                        phx-value-id={entry.source_id}
                        title="Re-render the HTML view from the current text"
                        style="font-size:0.72rem;padding:0.2rem 0.6rem;border-radius:0.3rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary);cursor:pointer"
                      >↻ Regen HTML</button>
                      <%= case @regen_html_status[entry.source_id] do %>
                        <% :ok -> %>
                          <span style="font-size:0.72rem;font-weight:600;color:var(--green)">✓ Regenerated</span>
                        <% :error -> %>
                          <span style="font-size:0.72rem;font-weight:600;color:var(--red)">✗ Failed</span>
                        <% _ -> %>
                      <% end %>
                    <% end %>
                  </div>
                  <.decision_log pages={entry.pages} />
                </div>
              <% end %>
              <button type="button" phx-click="add_source" class="btn-add-source">+ Add manual rules entry</button>
            </div>

            <%!-- Rulebook reader modal: roomy, page-separated, read-only view of
                 the in-memory source text (so a just-cleaned, unsaved result shows). --%>
            <%= if @expanded_source_id != nil do %>
              <% reader = Enum.find(@source_entries, &(&1.id == @expanded_source_id)) %>
              <%= if reader do %>
                <% pages = reader.pages %>
                <% page_count = length(pages) %>
                <% cur =
                  @source_page |> Map.get(reader.id, 0) |> max(0) |> min(max(page_count - 1, 0)) %>
                <% cur_page = Enum.at(pages, cur) %>
                <% layer = editor_layer(reader, @editor_tab) %>
                <% page_head =
                  "font-size:0.62rem;font-weight:700;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);margin:0 0 0.4rem 0;text-align:center" %>
                <% page_label = fn p ->
                  if p.printed, do: "Page #{p.printed} · Sheet #{p.sheet}", else: "Sheet #{p.sheet}"
                end %>
                <% tab_style = fn active ->
                  "font-size:0.72rem;padding:0.2rem 0.7rem;border-radius:0.3rem;cursor:pointer;border:1px solid var(--border);background:#{if active, do: "var(--accent)", else: "var(--bg-subtle)"};color:#{if active, do: "white", else: "var(--text-secondary)"}"
                end %>
                <div style="position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.55);display:flex;align-items:stretch;justify-content:center;padding:1.5rem">
                  <div
                    id="reader-modal"
                    phx-hook="ReaderKeys"
                    data-reader-id={reader.id}
                    phx-click-away="close_source"
                    phx-window-keydown="close_source"
                    phx-key="Escape"
                    style="background:var(--bg);border-radius:0.6rem;width:100%;height:100%;display:flex;flex-direction:column;box-shadow:0 12px 40px rgba(0,0,0,0.4)"
                  >
                    <div style="display:flex;align-items:center;gap:0.6rem;padding:0.4rem 1.1rem;border-bottom:1px solid var(--border)">
                      <strong style="font-size:0.95rem;flex-shrink:0">
                        {if String.trim(reader.label) != "", do: reader.label, else: "Rulebook"}
                      </strong>
                      <div style="display:flex;gap:0.35rem;margin-left:0.5rem">
                        <button
                          type="button"
                          phx-click="set_reader_mode"
                          phx-value-mode="scroll"
                          style={tab_style.(@reader_mode == "scroll")}
                        >Scroll</button>
                        <button
                          type="button"
                          phx-click="set_reader_mode"
                          phx-value-mode="paginated"
                          style={tab_style.(@reader_mode == "paginated")}
                        >Paginated</button>
                      </div>

                      <div style="margin-left:0.5rem">
                        <.layer_tabs
                          id={reader.id}
                          current={layer}
                          cleaned_available={cleaned_available?(reader)}
                        />
                      </div>

                      <div
                        :if={@reader_mode == "paginated" and page_count > 0}
                        style="margin-left:auto"
                      >
                        <.page_nav id={reader.id} pages={pages} cur={cur} />
                      </div>
                      <div style={
                        if(@reader_mode == "paginated" and page_count > 0,
                          do: "",
                          else: "margin-left:auto"
                        )
                      }>
                        <.page_detection_badge
                          id={reader.id}
                          pages={pages}
                          page_one={@page_one_input[reader.id]}
                        />
                      </div>

                      <button
                        type="button"
                        phx-click="close_source"
                        style={"font-size:1.1rem;line-height:1;background:none;border:none;cursor:pointer;color:var(--text-muted)#{if @reader_mode == "paginated", do: ";margin-left:0.5rem", else: ";margin-left:auto"}"}
                      >✕</button>
                    </div>

                    <% regenerating? = Map.get(@reextracting, reader.source_id, 0) > 0 %>
                    <% editable =
                      layer_editable?(reader, layer) and @cleaning[reader.source_id] == nil and
                        not regenerating? %>
                    <% edit_style =
                      "width:100%;box-sizing:border-box;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:0.9rem;line-height:1.6;color:var(--text);background:var(--bg);border:1px solid var(--border);border-radius:0.4rem;padding:1rem;resize:vertical#{if not editable, do: ";opacity:0.7;background:var(--bg-subtle)"}" %>
                    <%!-- Paginated mode: the box itself doesn't scroll — the top
                          matter (heading, flags, log) stays put and the textarea
                          fills the remaining height and scrolls internally. Scroll
                          mode (continuous read-only) does scroll the whole area. --%>
                    <div
                      id="reader-scroll"
                      style={"padding:0.5rem clamp(1.5rem,8vw,8rem) 1rem;flex:1;min-height:0;display:flex;flex-direction:column;overflow:#{if @reader_mode == "paginated", do: "hidden", else: "auto"}"}
                    >
                      <%= if @reader_mode == "paginated" do %>
                        <%= if cur_page do %>
                          <div style={page_head}>— {page_label.(cur_page)} —</div>
                          <.review_flag
                            id={reader.id}
                            pages={pages}
                            cur={cur}
                            can_reextract={reextractable_source?(reader)}
                            busy={regenerating?}
                          />
                          <textarea
                            name={"pgm_#{reader.id}_#{cur}_#{layer_field(layer)}"}
                            phx-change="edit_page"
                            phx-debounce="250"
                            style={"#{edit_style};flex:1;min-height:0;resize:none"}
                            readonly={not editable}
                          >{layer_text(cur_page, layer)}</textarea>
                        <% else %>
                          <p style="color:var(--text-muted)">No pages.</p>
                        <% end %>
                      <% else %>
                        <%!-- Scroll = read-only continuous view of the selected
                              layer (editing happens in the paginated mode). --%>
                        <%= for p <- pages do %>
                          <div style={page_head}>— {page_label.(p)} —</div>
                          <div style="font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:0.9rem;line-height:1.6;white-space:pre-wrap;color:var(--text)">
                            {layer_text(p, layer)}
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>

          <%!-- Danger tab --%>
          <div style={if @tab == "danger", do: "display:block", else: "display:none"}>
            <div
              class="border border-red-200 rounded-lg p-4"
              style="display:flex;flex-direction:column;gap:1rem"
            >
              <h2 class="text-sm font-semibold mb-1" style="color:var(--red)">Danger Zone</h2>

              <%!-- Clear questions --%>
              <%= if @question_count > 0 do %>
                <div style="padding-bottom:0.75rem;border-bottom:1px solid var(--border-subtle)">
                  <p class="text-xs text-gray-500 mb-2">
                    Clear all {@question_count} questions and answers for this game.
                  </p>
                  <%= if not @confirm_clear do %>
                    <button
                      type="button"
                      phx-click="confirm_clear"
                      style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                    >Clear All Questions</button>
                  <% else %>
                    <p class="text-xs font-medium mb-2" style="color:var(--red)">
                      Are you sure? This cannot be undone.
                    </p>
                    <div class="flex gap-2">
                      <button
                        type="button"
                        phx-click="clear_questions"
                        style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                      >Yes, clear all</button>
                      <button
                        type="button"
                        phx-click="cancel_clear"
                        style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                      >Cancel</button>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Clear rulebook sources --%>
              <%= if length(@source_entries) > 0 do %>
                <div style="padding-bottom:0.75rem;border-bottom:1px solid var(--border-subtle)">
                  <p class="text-xs text-gray-500 mb-2">
                    Remove all {length(@source_entries)} rulebook source(s) for this game.
                  </p>
                  <%= if not @confirm_clear_sources do %>
                    <button
                      type="button"
                      phx-click="confirm_clear_sources"
                      style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                    >Clear All Rulebook Sources</button>
                  <% else %>
                    <p class="text-xs font-medium mb-2" style="color:var(--red)">
                      Are you sure? This cannot be undone.
                    </p>
                    <div class="flex gap-2">
                      <button
                        type="button"
                        phx-click="clear_sources"
                        style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                      >Yes, clear all</button>
                      <button
                        type="button"
                        phx-click="cancel_clear_sources"
                        style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                      >Cancel</button>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Delete game --%>
              <div>
                <p class="text-xs text-gray-500 mb-2">
                  Permanently delete this game and all associated data (sources, questions, faq).
                </p>
                <%= if not @confirm_delete_game do %>
                  <button
                    type="button"
                    phx-click="confirm_delete_game"
                    style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                  >Delete Game</button>
                <% else %>
                  <p class="text-xs font-medium mb-2" style="color:var(--red)">
                    Are you sure? This permanently deletes <strong>{@game.name}</strong>
                    and all its data.
                  </p>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      phx-click="delete_game"
                      style="background:var(--red);color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                    >Yes, delete forever</button>
                    <button
                      type="button"
                      phx-click="cancel_delete_game"
                      style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                    >Cancel</button>
                  </div>
                <% end %>
              </div>

              <%= if @question_count == 0 and length(@source_entries) == 0 do %>
                <p class="text-xs text-gray-400">
                  Nothing to clear — no questions or rulebook sources yet.
                </p>
              <% end %>
            </div>
          </div>

          <div
            :if={@tab in ["details", "manage"]}
            class="flex gap-3"
            style="margin-top:1.5rem;padding-top:1rem;border-top:1px solid var(--border)"
          >
            <.button variant="primary" type="submit">Save</.button>
            <.button variant="secondary" navigate={~p"/"}>Cancel</.button>
          </div>
        </.form>
      </div>

      <!-- Cheatsheet panel -->
      <div
        style={"display:#{if @tab == "cheatsheet", do: "block", else: "none"}"}
        data-refresh={@cheat_refresh}
      >
        <%= if @game do %>
          <% doc_id = Games.list_documents(@game) |> Enum.map(& &1.id) |> Enum.at(0) %>
          <div class="mt-6 border rounded-lg p-4" data-refresh={@cheat_refresh}>
            <h2 class="text-sm font-semibold mb-2">Cheat Sheet</h2>

            <%= if @cheat_status && !@cheat_content do %>
              <p class="text-xs text-gray-500 mb-1">
                Generating <strong>{@cheat_level || "compact"}</strong> cheatsheet...
              </p>
              <p class="text-xs text-gray-400 mb-2">
                {@cheat_provider} &middot; {@cheat_model}
                <%= if @cheat_elapsed && @cheat_elapsed > 0 do %>
                  &middot; {format_elapsed(@cheat_elapsed)}
                <% end %>
              </p>
              <div class="w-full rounded-full mb-2" style="height:6px;background:var(--border)">
                <div
                  class="rounded-full animate-pulse"
                  style="width:100%;height:6px;background:var(--accent)"
                >
                </div>
              </div>
              <button
                type="button"
                phx-click="cancel_cheat_content"
                class="text-red-500 text-xs font-semibold bg-transparent border-none cursor-pointer"
              >Cancel</button>
            <% end %>

            <%= if @cheat_content do %>
              <p class="text-xs text-gray-400 mb-1">
                Generated <strong>{@cheat_level || "compact"}</strong>
                with {@cheat_provider} &middot; {@cheat_model}
                {if @cheat_elapsed, do: "in #{format_elapsed(@cheat_elapsed)}"}
              </p>
              <p class="text-xs text-gray-500 mb-2">Review and edit below, then save.</p>
              <form id="cheat-save-form" phx-submit="save_cheat">
                <textarea
                  name="content"
                  rows="16"
                  class="w-full border rounded px-3 py-2 font-mono text-xs mb-2"
                ><%= @cheat_content %></textarea>
                <div class="flex gap-2 mb-3">
                  <button
                    type="submit"
                    style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                  >
                    Save Cheat Sheet
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_cheat_content"
                    style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <%= if !@cheat_status do %>
                <%= if Enum.any?(@source_entries, &(&1[:source_id] || String.trim(&1.text || "") != "")) do %>
                  <p class="text-xs text-gray-500 mb-2">
                    Choose a density level and generate a cheat sheet from your rulebook text.
                  </p>
                  <%= if length(@cheat_expansions) > 0 do %>
                    <div style="display:flex;flex-wrap:wrap;gap:0.35rem;margin-bottom:0.75rem">
                      <span style="font-size:0.65rem;color:var(--text-muted);font-weight:600;align-self:center">Include expansions:</span>
                      <%= for exp <- @cheat_expansions do %>
                        <label
                          phx-click="toggle_cheat_expansion"
                          phx-value-id={exp.id}
                          style={"cursor:pointer;font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:0.3rem;#{if Map.get(@included_expansions, exp.id), do: "background:var(--accent);color:#fff", else: "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border)"}"}
                        >
                          <input
                            type="checkbox"
                            checked={Map.get(@included_expansions, exp.id)}
                            name={"exp_#{exp.id}"}
                            value="1"
                            style="display:none"
                          />
                          {exp.name}
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                  <form phx-submit="generate_cheat" class="flex items-center gap-3 mb-3">
                    <select name="level" class="border rounded px-2 py-1.5 text-xs">
                      <option value="ultra" selected={@cheat_level == "ultra"}>
                        Ultra - just the facts
                      </option>
                      <option value="compact" selected={@cheat_level == "compact"}>
                        Compact - key rules
                      </option>
                      <option value="standard" selected={@cheat_level == "standard"}>
                        Standard - balanced
                      </option>
                      <option value="detailed" selected={@cheat_level == "detailed"}>
                        Detailed - thorough
                      </option>
                      <option value="full" selected={@cheat_level == "full"}>
                        Full - everything
                      </option>
                    </select>
                    <button
                      type="submit"
                      disabled={@cheat_status != nil}
                      style="background:var(--accent);color:white;border:none;padding:0.4rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"
                    >
                      Generate
                    </button>
                  </form>
                <% else %>
                  <p class="text-xs text-gray-400 mb-3">
                    Add rulebook text or upload a PDF first, then generate a cheat sheet.
                  </p>
                <% end %>
              <% end %>
            <% end %>

            <% active = doc_id && CheatSheet.active_version(doc_id) %>
            <%= if active do %>
              <div class="flex items-center gap-3 mb-3">
                <.link
                  href={"/games/#{@game.id}/cheatsheet"}
                  target="_blank"
                  class="action-link"
                >
                  View active cheat sheet
                </.link>
                <span class="text-xs text-gray-400">|</span>
                <%= if @confirm_delete_cheat do %>
                  <span class="text-xs text-red-600">Delete all versions?</span>
                  <button
                    type="button"
                    phx-click="confirm_delete_cheat"
                    class="text-red-600 text-xs font-semibold bg-transparent border-none cursor-pointer"
                  >Yes</button>
                  <button
                    type="button"
                    phx-click="cancel_delete_cheat"
                    class="text-gray-500 text-xs bg-transparent border-none cursor-pointer"
                  >No</button>
                <% else %>
                  <button
                    type="button"
                    phx-click="delete_cheat"
                    class="text-red-600 text-xs font-semibold bg-transparent border-none cursor-pointer"
                  >Delete All</button>
                <% end %>
              </div>
            <% end %>

            <% versions = if doc_id, do: CheatSheet.list_versions(doc_id), else: [] %>
            <%= if length(versions) > 0 do %>
              <div class="pt-3 border-t">
                <p class="text-xs font-semibold text-gray-500 mb-2">
                  History ({length(versions)})
                </p>
                <div style="display:flex;flex-direction:column;gap:2px">
                  <%= for v <- versions do %>
                    <% badge = level_badge_style(v.level) %>
                    <div style={"display:flex;align-items:center;gap:0.5rem;padding:0.35rem 0.5rem;border-radius:0.25rem;font-size:0.7rem;#{if v.active, do: "background:var(--bg-subtle);border:1px solid var(--accent)", else: "background:var(--bg)"}"}>
                      <span style="width:110px;color:var(--text-muted);flex-shrink:0;font-family:monospace">
                        {v.inserted_at
                        |> NaiveDateTime.truncate(:second)
                        |> to_string()
                        |> String.slice(0, 16)}
                      </span>
                      <span style={"padding:0.1rem 0.35rem;border-radius:0.2rem;font-weight:600;text-transform:uppercase;font-size:0.6rem;#{badge}"}>
                        {v.level}
                      </span>
                      <span style="display:flex;align-items:center;gap:0;flex-shrink:0;margin-left:auto">
                        <.link
                          href={~p"/games/#{@game}/cheatsheet/#{RuleMaven.Hashid.encode(v.id)}"}
                          target="_blank"
                          style="color:var(--blue);font-weight:600;text-decoration:none;font-size:0.7rem"
                        >view</.link>
                        <span style="color:var(--border-strong);margin:0 0.35rem">|</span>
                        <span style="width:60px;text-align:center;display:inline-block">
                          <%= if v.active do %>
                            <span style="color:var(--accent);font-weight:600;font-size:0.65rem">active</span>
                          <% else %>
                            <button
                              type="button"
                              phx-click="set_active_version"
                              phx-value-id={v.id}
                              style="color:var(--blue);background:none;border:none;font-size:0.65rem;cursor:pointer;font-weight:500"
                            >set active</button>
                          <% end %>
                        </span>
                        <span style="color:var(--border-strong);margin:0 0.35rem">|</span>
                        <button
                          type="button"
                          phx-click="delete_version"
                          phx-value-id={v.id}
                          style="color:var(--red);background:none;border:none;font-size:0.65rem;cursor:pointer;font-weight:500"
                        >del</button>
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if @cheat_error do %>
              <p class="text-sm text-red-500 mt-2">{@cheat_error}</p>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # A game is "BGG-synced" once the detail pull has populated the enriched
  # fields. Catalog import only sets name/year/rank, so these stay nil until a
  # BGG sync (refresh_bgg → BggEnrichWorker) runs.
  defp bgg_synced?(game), do: Games.bgg_synced?(game)

  def format_elapsed(seconds) do
    if seconds < 60 do
      "#{seconds}s"
    else
      mins = div(seconds, 60)
      secs = rem(seconds, 60)
      "#{mins}m #{secs}s"
    end
  end

  defp parse_expansion_ids(params) do
    params
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "exp_") end)
    |> Enum.map(fn {k, _} -> String.replace_prefix(k, "exp_", "") end)
    |> Enum.map(&String.to_integer/1)
  end

  defp level_badge_style(level) do
    case level do
      "ultra" ->
        "background:var(--bg-subtle);color:var(--text-muted)"

      "compact" ->
        "background:var(--accent-subtle);color:var(--accent)"

      "standard" ->
        "background:var(--bg-surface);color:var(--accent-dark);border:1px solid var(--accent);font-weight:700"

      "detailed" ->
        "background:var(--accent-subtle);color:var(--accent);border:1px solid var(--accent-light)"

      "full" ->
        "background:var(--bg);color:var(--text-secondary);border:1px solid var(--border-strong)"

      _ ->
        "background:var(--bg-subtle);color:var(--text-muted)"
    end
  end
end
