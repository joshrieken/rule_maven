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
        game_changeset: nil,
        download_url: "",
        download_label: "",
        downloading: false,
        download_error: nil,
        download_ok: false,
        searching: false,
        bgg_results: [],
        search_error: nil,
        confirm_clear: false,
        confirm_clear_sources: false,
        confirm_delete_game: false,
        confirm_delete_cheat: false,
        question_count: 0,
        generating: false,
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
        bgg_search_error: nil
      )
      |> allow_upload(:rulebook_pdfs,
        accept: ["application/pdf"],
        max_entries: @max_pdfs,
        max_file_size: 50_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if RuleMaven.Users.game_master?(socket.assigns.current_user) do
      do_handle_params(params, socket)
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp do_handle_params(params, socket) do
    socket =
      case params do
        %{"id" => id} ->
          game = Games.get_game!(id)

          sources =
            game
            |> Games.list_rulebook_sources()
            |> Enum.with_index()
            |> Enum.map(fn {s, i} ->
              %{
                id: i,
                source_id: s.id,
                label: s.label,
                text: s.full_text,
                pdf_path: s.pdf_path,
                html_path: s.html_path
              }
            end)

          entries = if sources == [], do: [], else: sources

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

          tab = Map.get(params, "tab", "rulebook")
          socket = assign(socket, tab: tab)
          socket

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
    {:noreply, assign(socket, source_entries: entries ++ [%{id: next_id, label: "", text: ""}])}
  end

  @impl true
  def handle_event("remove_source", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entries = Enum.reject(socket.assigns.source_entries, &(&1.id == id))
    {:noreply, assign(socket, source_entries: entries)}
  end

  @impl true
  def handle_event("delete_source", %{"source_id" => source_id}, socket) do
    source_id = String.to_integer(source_id)

    source =
      socket.assigns.game
      |> Games.list_rulebook_sources()
      |> Enum.find(&(&1.id == source_id))

    if source do
      Games.delete_rulebook_source(source)
    end

    entries = Enum.reject(socket.assigns.source_entries, &(&1[:source_id] == source_id))
    {:noreply, assign(socket, source_entries: entries)}
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
  def handle_event("refresh_bgg", _params, socket) do
    socket = assign(socket, generating: true)
    send(self(), {:refresh_bgg})
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if socket.assigns.game do
      {:noreply, push_patch(socket, to: ~p"/games/#{socket.assigns.game}/edit?tab=#{tab}")}
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
    exp = Games.get_game!(id)
    Games.update_game(exp, %{parent_game_id: nil})

    game = Games.get_game!(socket.assigns.game.id)
    {:noreply, assign(socket, game: game, expansions: Games.expansions_for(game), cheat_expansions: Games.expansions_with_documents(game))}
  end

  @impl true
  def handle_event("generate_cheat", %{"level" => level} = params, socket) do
    game = socket.assigns.game
    expansion_ids = parse_expansion_ids(params)
    CheatSheet.generate_async(game, self(), level, expansion_ids)
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
    _game = socket.assigns.game
    refresh = socket.assigns.cheat_refresh + 1

    case Integer.parse(id) do
      {version_id, _} ->
        case CheatSheet.get_version!(version_id) do
          nil ->
            {:noreply, socket |> put_flash(:error, "Version not found.")}

          version ->
            CheatSheet.delete_version(version)

            {:noreply,
             socket |> assign(cheat_refresh: refresh) |> put_flash(:info, "Version deleted.")}
        end

      :error ->
        {:noreply, socket |> put_flash(:error, "Invalid version ID.")}
    end
  end

  @impl true
  def handle_event("set_active_version", %{"id" => id}, socket) do
    _game = socket.assigns.game
    refresh = socket.assigns.cheat_refresh + 1

    case Integer.parse(id) do
      {version_id, _} ->
        case CheatSheet.get_version!(version_id) do
          nil ->
            {:noreply, socket |> put_flash(:error, "Version not found.")}

          version ->
            CheatSheet.set_active(version)

            {:noreply,
             socket
             |> assign(cheat_refresh: refresh)
             |> put_flash(:info, "Version set as active.")}
        end

      :error ->
        {:noreply, socket |> put_flash(:error, "Invalid version ID.")}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("download", %{"url" => url, "label" => label}, socket) do
    url = String.trim(url)
    label = String.trim(label)
    socket = assign(socket, downloading: true, download_error: nil, download_ok: nil)

    if url == "" do
      {:noreply, assign(socket, downloading: false, download_error: "Enter a PDF URL")}
    else
      send(self(), {:download_rulebook, url, label})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("find_download", _params, socket) do
    socket = assign(socket, downloading: true, download_error: nil, download_ok: nil)
    send(self(), {:find_and_download})
    {:noreply, socket}
  end

  @impl true
  def handle_event("bgg_search", %{"search" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, bgg_search_results: [], bgg_search_error: nil)}
    else
      socket = assign(socket, bgg_search: query, bgg_searching: true, bgg_search_error: nil)
      send(self(), {:bgg_search, query})
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

    send(self(), {:pull_bgg_info, changeset})

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
    send(self(), {:search_bgg, game.bgg_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_download", %{"url" => url, "label" => label}, socket) do
    url = String.trim(url)
    label = String.trim(label)
    socket = assign(socket, downloading: true, download_error: nil)
    send(self(), {:download_rulebook, url, label})
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
        text = all_params["text_#{entry.id}"] || ""
        {label, %{full_text: text, pdf_path: nil}}
      end)
      |> Enum.filter(fn {l, %{full_text: t}} -> String.trim(l) != "" && String.trim(t) != "" end)

    pdf_texts =
      consume_uploaded_entries(socket, :rulebook_pdfs, fn %{path: path}, entry ->
        case extract_pdf_text(path, entry.client_name) do
          {:ok, text, pdf_path, html_path} ->
            label =
              entry.client_name
              |> Path.rootname()
              |> String.replace(~r/[_\-]/, " ")

            {:ok, {label, text, pdf_path, html_path}}

          {:error, reason, _} ->
            {:ok, {entry.client_name, "Error extracting text: #{reason}", nil, nil}}
        end
      end)

    merged =
      Enum.reduce(pdf_texts, source_map, fn {label, text, pdf_path, html_path}, acc ->
        case acc do
          %{^label => _} ->
            acc

          _ ->
            Keyword.put(acc, label, %{full_text: text, pdf_path: pdf_path, html_path: html_path})
        end
      end)
      |> Map.new()

    save_game(socket, socket.assigns.game, game_params, merged)
  end

  @impl true
  def handle_info({:download_rulebook, url, label}, socket) do
    game = socket.assigns.game

    case RulebookDownloader.download(game, url, label) do
      {:ok, source} ->
        # Reload sources to show new entry
        sources =
          game
          |> Games.list_rulebook_sources()
          |> Enum.with_index()
          |> Enum.map(fn {s, i} ->
            %{
              id: i,
              source_id: s.id,
              label: s.label,
              text: s.full_text,
              pdf_path: s.pdf_path,
              html_path: s.html_path
            }
          end)

        {:noreply,
         socket
         |> assign(
           downloading: false,
           download_error: nil,
           download_ok: source.pdf_path,
           source_entries: sources
         )
         |> put_flash(:info, "Rulebook downloaded!")}

      {:error, reason} ->
        {:noreply, assign(socket, downloading: false, download_error: reason)}
    end
  end

  @impl true
  def handle_info({:find_and_download}, socket) do
    game = socket.assigns.game

    case RulebookDownloader.find_and_download(game) do
      {:ok, source} ->
        sources =
          game
          |> Games.list_rulebook_sources()
          |> Enum.with_index()
          |> Enum.map(fn {s, i} ->
            %{
              id: i,
              source_id: s.id,
              label: s.label,
              text: s.full_text,
              pdf_path: s.pdf_path,
              html_path: s.html_path
            }
          end)

        {:noreply,
         socket
         |> assign(
           downloading: false,
           download_error: nil,
           download_ok: source.pdf_path,
           source_entries: sources
         )
         |> put_flash(:info, "Rulebook found and downloaded!")}

      {:error, reason} ->
        {:noreply, assign(socket, downloading: false, download_error: reason)}
    end
  end

  @impl true
  def handle_info({:search_bgg, bgg_id}, socket) do
    cookies = resolve_bgg_cookies()
    require Logger
    Logger.debug("Searching BGG for bgg_id=#{bgg_id} cookies=#{inspect(cookies != nil)}")

    case RulebookDownloader.find_on_bgg(bgg_id, cookies: cookies) do
      {:ok, results} ->
        Logger.debug("BGG search found #{length(results)} PDFs")

        search_error =
          cond do
            results == [] -> "No PDF rulebooks found on BGG files page"
            cookies == nil -> nil
            true -> nil
          end

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
  def handle_info({:refresh_bgg}, socket) do
    game = socket.assigns.game

    case RuleMaven.BGG.enrich_game(game, force: true) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(generating: false, game: updated)
         |> put_flash(:info, "Game info refreshed from BGG!")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(generating: false)
         |> put_flash(:error, "Failed to refresh: #{reason}")}
    end
  end

  @impl true
  def handle_info({:bgg_search, query}, socket) do
    result =
      try do
        RuleMaven.BGG.search(query)
      rescue
        e ->
          {:error, Exception.message(e)}
      end

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

  @impl true
  def handle_info({:pull_bgg_info, changeset}, socket) do
    case RuleMaven.BGG.fetch_game_info(changeset.data.bgg_id) do
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

  defp extract_pdf_text(path, client_name) do
    upload_dir = Application.app_dir(:rule_maven, "priv/static/uploads/rulebooks")
    File.mkdir_p!(upload_dir)

    filename = "#{System.system_time(:millisecond)}_#{client_name}"
    pdf_path = Path.join("uploads/rulebooks", filename)
    dest = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    case File.cp(path, dest) do
      :ok ->
        case System.cmd("pdftotext", [path, "-"]) do
          {text, 0} ->
            if String.trim(text) == "" do
              case ocr_text(path) do
                {:ok, ocr_text} ->
                  html_path = text_to_html(ocr_text, pdf_path)
                  {:ok, ocr_text, pdf_path, html_path}

                {:error, reason} ->
                  {:error, reason, pdf_path}
              end
            else
              html_path = text_to_html(text, pdf_path)
              {:ok, text, pdf_path, html_path}
            end

          {_output, _exit_code} ->
            case ocr_text(path) do
              {:ok, ocr_text} ->
                html_path = text_to_html(ocr_text, pdf_path)
                {:ok, ocr_text, pdf_path, html_path}

              {:error, reason} ->
                {:error, reason, pdf_path}
            end
        end

      {:error, reason} ->
        {:error, "Failed to save PDF: #{reason}", nil}
    end
  rescue
    e ->
      {:error, "pdftotext error: #{Exception.message(e)}", nil}
  end

  defp text_to_html(text, pdf_path) do
    html_filename = Path.basename(pdf_path, Path.extname(pdf_path)) <> ".html"
    html_path = Path.join(Path.dirname(pdf_path), html_filename)
    dest = Application.app_dir(:rule_maven, "priv/static/#{html_path}")

    pages = String.split(text, "\f")

    {paragraphs, _para_num} =
      pages
      |> Enum.with_index(1)
      |> Enum.reduce({[], 1}, fn {page_text, page_num}, {acc, para_num} ->
        page_text = String.trim(page_text)

        if page_text == "" do
          {acc, para_num}
        else
          page_paras =
            page_text
            |> String.split(~r{\n\s*\n})
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          marker = "<div class=\"page-break\">— Page #{page_num} —</div>"

          {page_acc, next_para} =
            Enum.reduce(page_paras, {[marker | acc], para_num}, fn para, {list, pn} ->
              para_html =
                "<p id=\"p#{pn}\" data-page=\"#{page_num}\">#{String.replace(para, "\n", "<br>")}</p>"

              {[para_html | list], pn + 1}
            end)

          {page_acc, next_para}
        end
      end)

    paragraphs_html = paragraphs |> Enum.reverse() |> Enum.join("\n")

    html = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <style>
      body { font-family: Georgia, serif; font-size: 14px; line-height: 1.6; max-width: 720px; margin: 2rem auto; padding: 0 1rem; color: #222; }
      p { margin: 0.5rem 0; }
      p:hover { background: #fffde7; }
      .page-break { margin: 1.5rem 0 0.5rem 0; font-size: 12px; color: #999; border-top: 1px dashed #ccc; padding-top: 0.5rem; font-weight: 600; }
    </style></head>
    <body>
    #{paragraphs_html}
    </body></html>
    """

    File.write!(dest, html)
    html_path
  rescue
    _ -> nil
  end

  defp ocr_text(pdf_path) do
    if System.find_executable("tesseract") do
      tmp_dir = Application.app_dir(:rule_maven, "tmp/ocr")
      File.mkdir_p!(tmp_dir)
      prefix = Path.join(tmp_dir, "#{System.system_time(:millisecond)}_page")

      case System.cmd("pdftoppm", ["-png", "-r", "300", pdf_path, prefix]) do
        {_, 0} ->
          images =
            tmp_dir
            |> File.ls!()
            |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
            |> Enum.sort()
            |> Enum.map(&Path.join(tmp_dir, &1))

          text =
            images
            |> Enum.map(fn img ->
              case System.cmd("tesseract", [img, "stdout", "-l", "eng", "--psm", "6"],
                     stderr_to_stdout: true
                   ) do
                {t, _} -> t
              end
            end)
            |> Enum.join("\f")

          Enum.each(images, &File.rm/1)

          if String.trim(text) == "" do
            {:error, "OCR produced no text — scanned PDF may be unreadable"}
          else
            {:ok, text}
          end

        {_, _} ->
          {:error, "pdftoppm failed"}
      end
    else
      {:error, "Scanned PDF. Install tesseract: brew install tesseract"}
    end
  end

  defp save_game(socket, nil, game_params, source_map) do
    case Games.create_game(game_params) do
      {:ok, game} ->
        Enum.each(source_map, fn {label,
                                  %{full_text: text, pdf_path: pdf_path, html_path: html_path}} ->
          Games.create_rulebook_source(%{
            game_id: game.id,
            label: label,
            full_text: text,
            pdf_path: pdf_path,
            html_path: html_path
          })
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Game created!")
         |> push_navigate(to: ~p"/games/#{game.id}/edit")}

      {:error, changeset} ->
        {:noreply, assign(socket, game_changeset: changeset)}
    end
  end

  defp save_game(socket, game, game_params, source_map) do
    case Games.update_game(game, game_params) do
      {:ok, game} ->
        existing = Games.list_rulebook_sources(game)

        existing
        |> Enum.filter(fn s -> not Map.has_key?(source_map, s.label) end)
        |> Enum.each(&Games.delete_rulebook_source/1)

        existing_labels = MapSet.new(existing, & &1.label)

        source_map
        |> Enum.filter(fn {label, _} -> not MapSet.member?(existing_labels, label) end)
        |> Enum.each(fn {label, %{full_text: text, pdf_path: pdf_path, html_path: html_path}} ->
          Games.create_rulebook_source(%{
            game_id: game.id,
            label: label,
            full_text: text,
            pdf_path: pdf_path,
            html_path: html_path
          })
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Game updated!")
         |> push_navigate(to: ~p"/games/#{game.id}/edit")}

      {:error, changeset} ->
        {:noreply, assign(socket, game_changeset: changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-form">
      <div class="mb-4 flex items-center justify-between">
        <.link navigate={~p"/"} class="text-blue-600 hover:underline text-sm">
          &larr; Back to games
        </.link>
        <.link
          :if={@game}
          navigate={~p"/games/#{@game.id}"}
          class="text-blue-600 hover:underline text-sm"
        >
          Ask questions &rarr;
        </.link>
      </div>

      <h1 class="text-2xl font-bold mb-6">
        {if @game, do: "Edit #{@game.name}", else: "Add Game"}
        <%= if @game && @game.bgg_id do %>
          <.link
            href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
            target="_blank"
            rel="noopener"
            class="text-blue-500 hover:underline text-sm font-normal ml-2"
          >
            View on BGG
          </.link>
          <button
            type="button"
            phx-click="refresh_bgg"
            style="color:var(--accent);background:none;border:none;font-size:0.75rem;font-weight:600;cursor:pointer;margin-left:0.5rem"
          >
            Refresh info
          </button>
        <% end %>
      </h1>

      <!-- Tabs -->
      <%= if @game do %>
      <div style="display:flex;border-bottom:1px solid var(--border);margin-bottom:1rem">
        <button type="button" phx-click="switch_tab" phx-value-tab="details"
          style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "details", do: "var(--blue)", else: "transparent"};color:#{if @tab == "details", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "details", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}>
          Details
        </button>
        <button type="button" phx-click="switch_tab" phx-value-tab="rulebook"
          style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "rulebook", do: "var(--blue)", else: "transparent"};color:#{if @tab == "rulebook", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "rulebook", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}>
          Rulebooks
        </button>
        <button type="button" phx-click="switch_tab" phx-value-tab="cheatsheet"
          style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "cheatsheet", do: "var(--blue)", else: "transparent"};color:#{if @tab == "cheatsheet", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "cheatsheet", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}>
          Cheatsheet
        </button>
        <button type="button" phx-click="switch_tab" phx-value-tab="danger"
          style={"cursor:pointer;padding:0.35rem 0.75rem;font-size:0.8rem;font-weight:600;border:none;border-bottom:2px solid #{if @tab == "danger", do: "var(--blue)", else: "transparent"};color:#{if @tab == "danger", do: "var(--blue)", else: "var(--text-muted)"};background:#{if @tab == "danger", do: "var(--bg-subtle)", else: "transparent"};border-radius:0.25rem 0.25rem 0 0"}>
          Danger
        </button>
      </div>
      <% end %>

      <%!-- New game: simple form, no tabs --%>
      <%= if is_nil(@game) do %>
        <div>
          <%= if @game_changeset && @game_changeset.data.bgg_id do %>
          <div class="flex gap-3 items-center mb-6 p-3 border rounded-lg bg-gray-50">
              <%= if @game_changeset.data.image_url do %>
                <img src={@game_changeset.data.image_url} alt="" style="width:80px;height:80px;object-fit:cover;border-radius:0.375rem;flex-shrink:0" />
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
              <input type="text" name="search" value={@bgg_search} placeholder="Search BGG by game name..." class="flex-1 border rounded px-3 py-2 text-sm" autocomplete="off" />
              <button type="submit" disabled={@bgg_searching} style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer;white-space:nowrap">Search</button>
            </form>
            <%= if @bgg_searching do %><p class="text-xs text-gray-400 mt-1">Searching...</p><% end %>
            <%= if @bgg_search_error do %><p class="text-xs text-red-500 mt-1">{@bgg_search_error}</p><% end %>
            <%= if @bgg_search_results != [] do %>
              <div class="mt-2 border rounded max-h-40 overflow-y-auto">
                <%= for result <- @bgg_search_results |> Enum.take(10) do %>
                  <button type="button" phx-click="bgg_select" phx-value-id={result.bgg_id} phx-value-name={result.name} class="w-full text-left px-3 py-1.5 text-sm hover:bg-gray-50 border-b last:border-b-0">
                    <span class="font-medium">{result.name}</span>
                    <span :if={result.year} class="text-gray-400 ml-2">({result.year})</span>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <div style={"display:#{if @game, do: "block", else: "none"}"}>
        <!-- BGG info bar (edit mode) -->
        <%= if @game_changeset && @game_changeset.data.bgg_id do %>
          <div class="flex gap-3 items-center mb-4 p-3 border rounded-lg bg-gray-50">
            <%= if @game_changeset.data.image_url do %>
              <img src={@game_changeset.data.image_url} alt="" style="width:80px;height:80px;object-fit:cover;border-radius:0.375rem;flex-shrink:0" />
            <% end %>
            <div>
              <p class="font-semibold">{@game_changeset.data.name}</p>
              <p class="text-xs text-gray-500">
                <%= if @game_changeset.data.year_published do %><%= @game_changeset.data.year_published %><% end %>
                <%= if @game_changeset.data.min_players do %> &middot; <%= @game_changeset.data.min_players %>-<%= @game_changeset.data.max_players %>p<% end %>
                <%= if @game_changeset.data.playing_time do %> &middot; ~<%= @game_changeset.data.playing_time %>m<% end %>
              </p>
              <p class="text-xs text-gray-400 mt-0.5">BGG ID: <%= @game_changeset.data.bgg_id %></p>
            </div>
          </div>
        <% end %>

        <.form for={@game_changeset} id="game-form" phx-change="validate" phx-submit="save" class="mt-6" style="max-width:56rem">
          <%!-- Details tab --%>
          <div style={if @tab == "details", do: "display:block", else: "display:none"}>
            <div style="margin-bottom:1.25rem">
              <label for="game_name" class="block text-sm font-medium mb-1">Game Name</label>
              <input type="text" name="game[name]" id="game_name" value={@game_changeset.data.name} class="w-full border rounded px-3 py-2" required />
            </div>
            <div style="margin-bottom:1.25rem">
              <label for="game_bgg_id" class="block text-sm font-medium mb-1">BGG ID <span class="text-gray-400">(optional)</span></label>
              <input type="number" name="game[bgg_id]" id="game_bgg_id" value={@game_changeset.data.bgg_id} class="w-full border rounded px-3 py-2" />
            </div>

            <%= if @game do %>
              <% parent_id = @game_changeset.data.parent_game_id || @game.parent_game_id %>
              <%= if parent_id do %>
                <% parent = Games.get_game!(parent_id) %>
                <div style="margin-bottom:0.5rem">
                  <span style="font-size:0.75rem;color:var(--text-muted)">Expansion of</span>
                  <.link navigate={~p"/games/#{parent.id}/edit"} style="font-size:0.8rem;color:var(--blue);font-weight:600;margin-left:0.25rem">{parent.name} →</.link>
                </div>
              <% end %>
              <% base_games = Games.list_base_games() |> Enum.reject(&(&1.id == @game.id)) %>
              <div style="margin-bottom:1.25rem">
                <label for="game_parent_game_id" class="block text-sm font-medium mb-1">Base Game <span class="text-gray-400">(optional — set if this is an expansion)</span></label>
                <select name="game[parent_game_id]" id="game_parent_game_id" class="w-full border rounded px-3 py-2 text-sm">
                  <option value="">None (standalone game)</option>
                  <%= for base <- base_games do %>
                    <option value={base.id} selected={@game_changeset.data.parent_game_id == base.id}><%= base.name %></option>
                  <% end %>
                </select>
              </div>
            <% end %>

            <%= if @game && length(@expansions) > 0 do %>
              <div style="margin-bottom:1.25rem">
                <h3 class="text-sm font-semibold mb-1">Expansions of this game</h3>
                <div class="space-y-1">
                  <%= for exp <- @expansions do %>
                    <div class="flex items-center justify-between border rounded px-3 py-1.5 text-sm">
                      <.link navigate={~p"/games/#{exp.id}/edit"} class="text-blue-600 hover:underline"><%= exp.name %></.link>
                      <button type="button" phx-click="unlink_expansion" phx-value-id={exp.id} class="text-xs" style="color:#dc2626;background:none;border:none;cursor:pointer;font-weight:600">Unlink</button>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Rulebooks tab --%>
          <div style={if @tab == "rulebook", do: "display:block", else: "display:none"}>
            <div class="space-y-4">
              <h2 class="text-lg font-semibold">Rulebook Sources</h2>
              <%= for entry <- @source_entries do %>
                <div class="border rounded p-4">
                  <div class="flex gap-2 items-start">
                    <div class="flex-1">
                      <label class="block text-sm font-medium mb-1">Label</label>
                      <input type="text" name={"label_#{entry.id}"} value={entry.label} placeholder="e.g. Core Rulebook" class="w-full border rounded px-3 py-2" />
                    </div>
                    <div class="flex-1">
                      <label class="block text-sm font-medium mb-1">Text</label>
                      <textarea name={"text_#{entry.id}"} rows="8" class="w-full border rounded px-3 py-2 font-mono text-xs" placeholder="Paste rulebook text here..."><%= entry.text %></textarea>
                    </div>
                    <div class="flex flex-col gap-1">
                      <button :if={length(@source_entries) > 1} type="button" phx-click="remove_source" phx-value-id={entry.id} class="btn-remove-source">✕</button>
                      <button :if={entry[:source_id]} type="button" phx-click="delete_source" phx-value-source_id={entry.source_id} style="color:#dc2626;background:none;border:none;font-size:0.75rem;cursor:pointer;white-space:nowrap;margin-top:0.25rem">Delete</button>
                    </div>
                  </div>
                  <%= if entry[:pdf_path] do %>
                    <div class="mt-2 flex gap-3">
                      <.link href={"/#{entry.pdf_path}"} target="_blank" class="text-blue-600 hover:underline text-xs">View PDF</.link>
                      <%= if entry[:html_path] do %><.link href={"/#{entry.html_path}"} target="_blank" class="text-green-600 hover:underline text-xs">View as HTML</.link><% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <button type="button" phx-click="add_source" class="btn-add-source">+ Add manual rules entry</button>
            </div>

            <div class="border-2 border-dashed border-gray-300 rounded-lg p-6 text-center">
              <label class="block text-sm font-medium mb-2">Or upload PDF rulebooks</label>
              <.live_file_input upload={@uploads.rulebook_pdfs} class="block mx-auto text-sm" />
              <%= for entry <- @uploads.rulebook_pdfs.entries do %><p class="text-xs text-gray-500 mt-1"><%= entry.client_name %> (<%= entry.progress %>%)</p><% end %>
            </div>

            <%!-- Download rulebook from URL --%>
            <div class="border rounded-lg p-4" style="margin-top:1.25rem">
              <h2 class="text-lg font-semibold mb-3">Download rulebook from URL</h2>
              <div class="flex gap-2 mb-3">
                <button type="button" phx-click="find_download" disabled={@downloading} style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Find &amp; Download</button>
                <%= if @game.bgg_id do %>
                  <button type="button" phx-click="search_bgg" disabled={@searching} style="background:var(--accent);color:white;border:none;padding:0.25rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer"><%= if @searching, do: "Searching BGG...", else: "Find on BGG" %></button>
                <% end %>
              </div>
              <%= if @game.bgg_id do %>
                <%= if @search_error do %>
                  <p class="text-sm text-red-500 mb-2"><%= @search_error %></p>
                <% end %>
                <%= if @bgg_results != [] do %>
                  <div class="border rounded p-2 mb-3 max-h-48 overflow-y-auto space-y-1">
                    <%= for result <- @bgg_results do %>
                      <div class="flex items-center justify-between text-xs p-1 hover:bg-gray-50 rounded">
                        <span class="truncate"><%= result.label %></span>
                        <button type="button" phx-click="search_download" phx-value-url={result.url} phx-value-label={result.label} disabled={@downloading} style="color:var(--accent);border:none;background:none;font-size:0.75rem;font-weight:600;cursor:pointer;white-space:nowrap;margin-left:0.5rem">Download</button>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
              <form phx-submit="download" style="margin-top:0.75rem">
                <div style="margin-bottom:0.75rem"><label class="block text-xs font-medium mb-1 text-gray-500">PDF URL</label><input type="text" name="url" value={@download_url} placeholder="https://example.com/rulebook.pdf" class="w-full border rounded px-3 py-2 text-sm" disabled={@downloading} /></div>
                <div style="margin-bottom:0.75rem"><label class="block text-xs font-medium mb-1 text-gray-500">Label (optional)</label><input type="text" name="label" value={@download_label} placeholder="e.g. Core Rulebook" class="w-full border rounded px-3 py-2 text-sm" disabled={@downloading} /></div>
                <button type="submit" disabled={@downloading} style="background:var(--accent);color:white;border:none;padding:0.5rem 1rem;border-radius:0.375rem;font-weight:600;font-size:0.875rem;cursor:pointer"><%= if @downloading, do: "Downloading...", else: "Download & Extract" %></button>
              </form>
              <%= if @download_ok do %><p class="text-sm mt-2" style="color:#166534">Downloaded! <.link href={"/#{@download_ok}"} target="_blank" class="underline font-semibold">View PDF</.link> or go to the <.link navigate={~p"/games/#{@game.id}"} class="underline font-semibold">Ask page</.link>.</p><% end %>
              <%= if @download_error do %><p class="text-sm text-red-500 mt-2"><%= @download_error %></p><% end %>
            </div>
          </div>

          <%!-- Danger tab --%>
          <div style={if @tab == "danger", do: "display:block", else: "display:none"}>
            <div class="border border-red-200 rounded-lg p-4" style="display:flex;flex-direction:column;gap:1rem">
              <h2 class="text-sm font-semibold mb-1" style="color:#dc2626">Danger Zone</h2>

              <%!-- Clear questions --%>
              <%= if @question_count > 0 do %>
                <div style="padding-bottom:0.75rem;border-bottom:1px solid var(--border-subtle)">
                  <p class="text-xs text-gray-500 mb-2">Clear all {@question_count} questions and answers for this game.</p>
                  <%= if not @confirm_clear do %>
                    <button type="button" phx-click="confirm_clear" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Clear All Questions</button>
                  <% else %>
                    <p class="text-xs font-medium mb-2" style="color:#dc2626">Are you sure? This cannot be undone.</p>
                    <div class="flex gap-2">
                      <button type="button" phx-click="clear_questions" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Yes, clear all</button>
                      <button type="button" phx-click="cancel_clear" style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Cancel</button>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Clear rulebook sources --%>
              <%= if length(@source_entries) > 0 do %>
                <div style="padding-bottom:0.75rem;border-bottom:1px solid var(--border-subtle)">
                  <p class="text-xs text-gray-500 mb-2">Remove all {length(@source_entries)} rulebook source(s) for this game.</p>
                  <%= if not @confirm_clear_sources do %>
                    <button type="button" phx-click="confirm_clear_sources" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Clear All Rulebook Sources</button>
                  <% else %>
                    <p class="text-xs font-medium mb-2" style="color:#dc2626">Are you sure? This cannot be undone.</p>
                    <div class="flex gap-2">
                      <button type="button" phx-click="clear_sources" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Yes, clear all</button>
                      <button type="button" phx-click="cancel_clear_sources" style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Cancel</button>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Delete game --%>
              <div>
                <p class="text-xs text-gray-500 mb-2">Permanently delete this game and all associated data (sources, questions, faq).</p>
                <%= if not @confirm_delete_game do %>
                  <button type="button" phx-click="confirm_delete_game" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Delete Game</button>
                <% else %>
                  <p class="text-xs font-medium mb-2" style="color:#dc2626">Are you sure? This permanently deletes <strong>{@game.name}</strong> and all its data.</p>
                  <div class="flex gap-2">
                    <button type="button" phx-click="delete_game" style="background:#dc2626;color:white;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Yes, delete forever</button>
                    <button type="button" phx-click="cancel_delete_game" style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.3rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.75rem;cursor:pointer">Cancel</button>
                  </div>
                <% end %>
              </div>

              <%= if @question_count == 0 and length(@source_entries) == 0 do %>
                <p class="text-xs text-gray-400">Nothing to clear — no questions or rulebook sources yet.</p>
              <% end %>
            </div>
          </div>

          <div :if={@tab in ["details", "rulebook"]} class="flex gap-3" style="margin-top:1.5rem;padding-top:1rem;border-top:1px solid var(--border)">
            <.button variant="primary" type="submit">Save</.button>
            <.button variant="secondary" navigate={~p"/"}>Cancel</.button>
          </div>
        </.form>
      </div>

      <!-- Cheatsheet panel -->
      <div style={"display:#{if @tab == "cheatsheet", do: "block", else: "none"}"} data-refresh={@cheat_refresh}>
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
                  class="text-blue-600 hover:underline text-sm font-semibold"
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
                          href={"/games/#{@game.id}/cheatsheet/#{v.id}"}
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
                          style="color:#dc2626;background:none;border:none;font-size:0.65rem;cursor:pointer;font-weight:500"
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
        "background:rgba(180,136,32,0.1);color:#d4a030;border:1px solid rgba(180,136,32,0.3)"

      "full" ->
        "background:var(--bg);color:var(--text-secondary);border:1px solid var(--border-strong)"

      _ ->
        "background:var(--bg-subtle);color:var(--text-muted)"
    end
  end
end
