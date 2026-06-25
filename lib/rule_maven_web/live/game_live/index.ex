defmodule RuleMavenWeb.GameLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, BggRefresher}

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    collection_ids = Games.collection_game_ids(user_id)

    # Default landing view: askable games (those with rulebooks). Users can
    # toggle to their collection or browse the full catalog.
    view = "playable"
    games = load_view_games(view, user_id, "", nil)

    {refresh_total, refresh_current, refresh_complete, refresh_errored} =
      if BggRefresher.running?() do
        BggRefresher.subscribe(self())

        case BggRefresher.state() do
          nil -> {0, 0, false, false}
          s -> {s.total, s.current, s.complete, Map.get(s, :errored, false)}
        end
      else
        {0, 0, false, false}
      end

    socket =
      socket
      |> assign(
        view: view,
        collection_ids: collection_ids,
        confirm_clear: false,
        confirm_text: "",
        search: if(connected?(socket), do: nil, else: ""),
        search_ready: false,
        delete_id: nil,
        page: 1,
        per_page: 20,
        selected_idx: -1,
        display_count: 20,
        expanded_games: %{},
        category_filter: nil,
        refresh_total: refresh_total,
        refresh_current: refresh_current,
        refresh_complete: refresh_complete,
        refresh_errored: refresh_errored,
        version: 0
      )
      |> assign_games(games)

    {:ok, socket}
  end

  # Load the game list for a view. "all" is DB-backed (catalog can be huge);
  # "mine"/"playable" are bounded lists filtered in-memory by the render path.
  defp load_view_games("mine", user_id, _search, _category), do: Games.list_collection(user_id)

  defp load_view_games("all", _user_id, search, category),
    do: Games.search_catalog(search || "", category: category)

  defp load_view_games(_playable, _user_id, _search, _category),
    do: Games.list_games_with_documents()

  # Assign the current games plus their expansion/source counts. Counts are
  # computed only for the games actually shown, so this stays cheap even when
  # the catalog has 150k rows.
  defp assign_games(socket, games) do
    is_admin = RuleMaven.Users.game_master?(socket.assigns.current_user)

    expansion_counts =
      Map.new(games, fn game ->
        exps =
          if is_admin, do: Games.expansions_for(game), else: Games.expansions_with_documents(game)

        {game.id, length(exps)}
      end)

    source_counts =
      Map.new(games, fn game -> {game.id, length(Games.list_documents(game))} end)

    assign(socket,
      games: games,
      expansion_counts: expansion_counts,
      source_counts: source_counts
    )
  end

  # Reload the games for the current view/search/category and recompute counts.
  defp reload_games(socket) do
    %{view: view, search: search, category_filter: category} = socket.assigns
    games = load_view_games(view, socket.assigns.current_user.id, search || "", category)
    assign_games(socket, games)
  end

  # "all" view is DB-backed, so search/category changes must re-query.
  defp maybe_reload_for_all(socket) do
    if socket.assigns.view == "all", do: reload_games(socket), else: socket
  end

  @impl true
  def handle_event("toggle_expansions", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    expanded = socket.assigns.expanded_games

    expanded =
      if expanded[id] do
        Map.delete(expanded, id)
      else
        Map.put(expanded, id, true)
      end

    {:noreply, assign(socket, expanded_games: expanded)}
  end

  @impl true
  def handle_event("confirm_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: true)}
  end

  @impl true
  def handle_event("confirm_cancel", _params, socket) do
    {:noreply, assign(socket, confirm_clear: false, confirm_text: "")}
  end

  @impl true
  def handle_event("confirm_input", params, socket) do
    text = params["value"] || params["confirm_text"] || ""
    {:noreply, assign(socket, confirm_text: text)}
  end

  @impl true
  def handle_event("delete_game", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    {:noreply, assign(socket, delete_id: id)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_id: nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    game = Games.get_game!(id)

    case Games.delete_game(game) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(delete_id: nil)
         |> reload_games()
         |> put_flash(:info, "Deleted #{game.name}.")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete #{game.name}.")}
    end
  end

  @impl true
  def handle_event("go_to_game", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    source_count = Map.get(socket.assigns.source_counts, id, 0)

    dest =
      if source_count == 0 and RuleMaven.Users.game_master?(socket.assigns.current_user),
        do: ~p"/games/#{id}/edit",
        else: ~p"/games/#{id}"

    {:noreply, push_navigate(socket, to: dest)}
  end

  @impl true
  def handle_event("key_nav", %{"key" => key}, socket) do
    visible = visible_games(socket.assigns)

    case key do
      "ArrowDown" ->
        next = min(socket.assigns.selected_idx + 1, length(visible) - 1)

        {:noreply,
         assign(socket, selected_idx: next) |> push_event("scroll_to_game", %{idx: next})}

      "ArrowUp" ->
        prev = max(socket.assigns.selected_idx - 1, 0)

        {:noreply,
         assign(socket, selected_idx: prev) |> push_event("scroll_to_game", %{idx: prev})}

      "unselect" ->
        {:noreply, assign(socket, selected_idx: -1)}

      "Enter" ->
        idx = socket.assigns.selected_idx

        if idx >= 0 && idx < length(visible) do
          game = Enum.at(visible, idx)
          source_count = Map.get(socket.assigns.source_counts, game.id, 0)

          dest =
            if source_count == 0 and RuleMaven.Users.game_master?(socket.assigns.current_user),
              do: ~p"/games/#{game.id}/edit",
              else: ~p"/games/#{game.id}"

          {:noreply, push_navigate(socket, to: dest)}
        else
          {:noreply, socket}
        end

      "e" ->
        if RuleMaven.Users.game_master?(socket.assigns.current_user) do
          idx = socket.assigns.selected_idx

          if idx >= 0 && idx < length(visible) do
            game = Enum.at(visible, idx)
            {:noreply, push_navigate(socket, to: ~p"/games/#{game.id}/edit")}
          else
            {:noreply, socket}
          end
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("key_nav", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"search" => text}, socket) do
    {:noreply,
     socket
     |> assign(search: text, search_ready: true, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()}
  end

  @impl true
  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(search: "", search_ready: true, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()
     |> push_event("refocus", %{})}
  end

  @impl true
  def handle_event("restore_search", %{"value" => text}, socket) do
    {:noreply,
     socket
     |> assign(search: text, search_ready: true, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()}
  end

  @impl true
  def handle_event("set_category_filter", %{"category" => category}, socket) do
    filter = if category == "", do: nil, else: category

    {:noreply,
     socket
     |> assign(category_filter: filter, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()}
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply,
     socket
     |> assign(view: view, display_count: 20, selected_idx: -1)
     |> reload_games()}
  end

  @impl true
  def handle_event("toggle_collection", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user_id = socket.assigns.current_user.id

    if MapSet.member?(socket.assigns.collection_ids, id) do
      Games.remove_from_collection(user_id, id)
    else
      Games.add_to_collection(user_id, id)
    end

    collection_ids = Games.collection_game_ids(user_id)
    socket = assign(socket, collection_ids: collection_ids)
    # Reflect membership change immediately when viewing the collection.
    socket = if socket.assigns.view == "mine", do: reload_games(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, assign(socket, display_count: socket.assigns.display_count + 20)}
  end

  @impl true
  def handle_event("clear_all_games", _params, socket) do
    {count, _} = Games.delete_all_games()

    {:noreply,
     socket
     |> assign(games: [], confirm_clear: false, confirm_text: "", search: "")
     |> put_flash(:info, "Cleared #{count} game(s).")}
  end

  @impl true
  def handle_event("start_refresh", _params, socket) do
    games =
      if RuleMaven.Users.game_master?(socket.assigns.current_user) do
        Games.list_games()
      else
        Games.list_games_with_documents()
      end
      |> Enum.filter(& &1.bgg_id)
      |> Enum.sort_by(&String.downcase(&1.name))

    result =
      if socket.assigns.refresh_errored do
        BggRefresher.restart(games)
      else
        BggRefresher.start(games)
      end

    case result do
      {:ok, _pid} ->
        BggRefresher.subscribe(self())

        {:noreply,
         assign(socket,
           refresh_total: length(games),
           refresh_current: 0,
           refresh_complete: false,
           refresh_errored: false
         )}

      {:error, :already_running} ->
        BggRefresher.subscribe(self())

        case BggRefresher.state() do
          nil ->
            {:noreply, socket}

          s ->
            {:noreply,
             assign(socket,
               refresh_total: s.total,
               refresh_current: s.current,
               refresh_complete: s.complete
             )}
        end
    end
  end

  defp visible_games(assigns) do
    filtered = filtered_games(assigns.games, assigns.search, assigns.category_filter)
    Enum.take(filtered, assigns.display_count)
  end

  defp filtered_games(_games, nil, _category), do: []

  defp filtered_games(games, search, category) do
    games
    |> apply_category_filter(category)
    |> apply_search_filter(search)
  end

  defp apply_category_filter(games, nil), do: games

  defp apply_category_filter(games, category) do
    Enum.filter(games, fn g -> (g.category || "board_game") == category end)
  end

  defp apply_search_filter(games, ""), do: games

  defp apply_search_filter(games, search) do
    search = String.downcase(search)

    Enum.filter(games, fn g ->
      String.contains?(String.downcase(g.name), search)
    end)
  end

  @impl true
  def handle_info({:progress, _name, current, total}, socket) do
    {:noreply, assign(socket, refresh_current: current, refresh_total: total)}
  end

  @impl true
  def handle_info({:done, _name, _status}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:complete}, socket) do
    {:noreply, assign(socket, refresh_complete: true)}
  end

  @impl true
  def handle_info({:refresh_error, _reason}, socket) do
    {:noreply, assign(socket, refresh_errored: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-list">
      <form phx-change="search" phx-submit="search" class="mb-4">
        <div style="position:relative;display:flex;align-items:center">
          <input
            type="text"
            id="game-search"
            name="search"
            value={@search}
            placeholder="Filter by name..."
            class="w-full border rounded px-3 py-2 pr-8 text-sm"
            autocomplete="off"
            autofocus
            phx-hook="Refocus"
          />
          <button
            :if={@search != ""}
            type="button"
            phx-click="clear_search"
            style="position:absolute;right:0.5rem;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--text-muted);font-size:0.85rem;cursor:pointer;padding:0;line-height:1;height:1.2rem;display:flex;align-items:center"
          >✕</button>
        </div>
      </form>

      <div class="mb-4 flex gap-2 flex-wrap">
        <%= for {key, label} <- [{"playable", "Playable"}, {"mine", "My Collection"}, {"all", "All Games"}] do %>
          <button
            type="button"
            phx-click="set_view"
            phx-value-view={key}
            style={"display:inline-block;padding:0.25rem 0.75rem;border-radius:9999px;font-size:0.78rem;font-weight:600;cursor:pointer;border:1.5px solid var(--accent);background:#{if @view == key, do: "var(--accent)", else: "transparent"};color:#{if @view == key, do: "white", else: "var(--accent)"}"}
          >{label}</button>
        <% end %>
      </div>

      <% present_categories =
        @games
        |> Enum.map(&(&1.category || "board_game"))
        |> Enum.uniq()
        |> Enum.sort() %>

      <%= if length(present_categories) > 1 do %>
        <div class="mb-4 flex gap-2 flex-wrap">
          <button
            type="button"
            phx-click="set_category_filter"
            phx-value-category=""
            style={"display:inline-block;padding:0.25rem 0.75rem;border-radius:9999px;font-size:0.78rem;font-weight:600;cursor:pointer;border:1.5px solid var(--blue);background:#{if is_nil(@category_filter), do: "var(--blue)", else: "transparent"};color:#{if is_nil(@category_filter), do: "white", else: "var(--blue)"}"}
          >All</button>
          <%= for cat <- present_categories do %>
            <button
              type="button"
              phx-click="set_category_filter"
              phx-value-category={cat}
              style={"display:inline-block;padding:0.25rem 0.75rem;border-radius:9999px;font-size:0.78rem;font-weight:600;cursor:pointer;border:1.5px solid var(--blue);background:#{if @category_filter == cat, do: "var(--blue)", else: "transparent"};color:#{if @category_filter == cat, do: "white", else: "var(--blue)"}"}
            ><%= RuleMaven.Games.Category.label(cat) %></button>
          <% end %>
        </div>
      <% end %>

      <div :if={RuleMaven.Users.game_master?(@current_user)} class="mb-4 flex gap-2 flex-wrap">
        <.button variant="primary" navigate={~p"/games/new"}>+ Add Game</.button>
        <.button variant="secondary" navigate={~p"/games/import"}>Import from BGG</.button>

        <%= if @games != [] do %>
          <button
            type="button"
            phx-click="start_refresh"
            style="display:inline-block;background:var(--accent);color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
            disabled={@refresh_total > 0 and not @refresh_complete}
          >
            {if @refresh_total > 0 and not @refresh_complete,
              do: "Refreshing...",
              else: "Refresh All from BGG"}
          </button>

          <%= if not @confirm_clear do %>
            <button
              type="button"
              phx-click="confirm_clear"
              style="background:var(--red);color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
            >
              Clear All Games
            </button>
          <% else %>
            <form phx-change="confirm_input" style="display:inline">
              <span class="text-sm font-medium" style="color:var(--red)">Type DELETE to confirm:</span>
              <input
                type="text"
                name="confirm_text"
                value={@confirm_text}
                placeholder="DELETE"
                style="border:1px solid var(--red);border-radius:0.375rem;padding:0.25rem 0.5rem;font-size:0.8rem;width:6rem"
              />
            </form>
            <button
              type="button"
              phx-click="clear_all_games"
              disabled={@confirm_text != "DELETE"}
              style="background:var(--red);color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
            >
              Delete All
            </button>
            <button
              type="button"
              phx-click="confirm_cancel"
              style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
            >
              Cancel
            </button>
          <% end %>
        <% end %>
      </div>

      <%!-- BGG refresh progress bar --%>
      <%= if @refresh_total > 0 and not @refresh_complete do %>
        <div
          style={"margin-bottom:0.75rem;padding:0.6rem 0.75rem;background:var(--bg);border:1px solid #{if @refresh_errored, do: "var(--red)", else: "var(--accent)"};border-radius:0.5rem;display:flex;align-items:center;gap:0.75rem;flex-wrap:wrap"}
          data-refresh={@version}
        >
          <span style={"font-size:0.75rem;font-weight:600;color:#{if @refresh_errored, do: "var(--red)", else: "var(--accent)"};white-space:nowrap"}>
            {if @refresh_errored, do: "BGG Refresh Failed", else: "BGG Refresh"}
          </span>
          <div style="flex:1;min-width:100px;height:6px;background:var(--border);border-radius:3px;overflow:hidden">
            <div style={"width:#{if @refresh_total > 0, do: trunc(@refresh_current / @refresh_total * 100), else: 0}%;height:100%;background:#{if @refresh_errored, do: "var(--red)", else: "var(--accent)"};transition:width 0.3s"}>
            </div>
          </div>
          <span style="font-size:0.7rem;color:var(--text-muted);white-space:nowrap">{@refresh_current}/{@refresh_total}</span>
          <.link
            navigate={~p"/games/refresh"}
            style="font-size:0.7rem;color:var(--blue);white-space:nowrap"
          >detail</.link>
        </div>
      <% end %>

      <% filtered = filtered_games(@games, @search, @category_filter) %>
      <% display_games = visible_games(assigns) %>

      <%= if @search != nil do %>
        <div class="space-y-3" id="game-list" phx-hook="GameListScroll">
          <%= for {game, idx} <- Enum.with_index(display_games) do %>
            <% expansion_count = Map.get(@expansion_counts, game.id, 0) %>
            <% expanded = Map.get(@expanded_games, game.id) %>
            <div
              id={"game-card-#{idx}"}
              class="border rounded-lg p-4 flex items-center gap-4 game-card"
              phx-click="go_to_game"
              phx-value-id={game.id}
              style={"cursor:pointer;#{if @selected_idx == idx, do: "outline:2px solid var(--accent);outline-offset:-2px;background:var(--bg-subtle)", else: ""}"}
            >
              <%= if game.image_url do %>
                <img
                  src={game.image_url}
                  alt={game.name}
                  style="width:60px;height:60px;object-fit:cover;border-radius:0.375rem;flex-shrink:0;pointer-events:none"
                />
              <% end %>
              <div class="flex-1 min-w-0" style="pointer-events:none">
                <h2 class="text-lg font-semibold">{game.name}</h2>
                <p class="text-sm text-gray-500">
                  <span style="font-size:0.7rem;font-weight:600;opacity:0.65">{RuleMaven.Games.Category.label(game.category)}</span>
                  &middot; {Map.get(@source_counts, game.id, 0)} source(s)
                  <%= if game.year_published do %>
                    &middot; {game.year_published}
                  <% end %>
                  <%= if game.min_players && RuleMaven.Games.Category.player_count_relevant?(game.category) do %>
                    &middot; {game.min_players}-{game.max_players}p
                  <% end %>
                  <%= if game.playing_time && RuleMaven.Games.Category.player_count_relevant?(game.category) do %>
                    &middot; ~{game.playing_time}m
                  <% end %>
                  <%= if expansion_count > 0 do %>
                    &middot;
                    <span style="color:var(--accent);font-weight:600">{expansion_count} expansion(s)</span>
                  <% end %>
                </p>
              </div>
              <div class="flex gap-1.5 flex-shrink-0 game-actions items-center">
                <%= if expansion_count > 0 do %>
                  <button
                    type="button"
                    phx-click="toggle_expansions"
                    phx-value-id={game.id}
                    style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);font-size:0.75rem;font-weight:600;cursor:pointer;padding:0.2rem 0.5rem;border-radius:0.3rem;line-height:1.2"
                  >{if expanded, do: "▲", else: "▼"} {expansion_count}</button>
                <% end %>
                <a
                  :if={game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(game.category)}
                  id={"bgg-link-#{game.id}"}
                  href={"https://boardgamegeek.com/boardgame/#{game.bgg_id}"}
                  target="_blank"
                  rel="noopener"
                  phx-hook="ExternalLink"
                  style="background:var(--bg-subtle);color:#ea580c;text-decoration:none;font-size:0.75rem;font-weight:600;cursor:pointer;padding:0.2rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border);line-height:1.2"
                >BGG</a>
                <.link
                  :if={Map.get(@source_counts, game.id, 0) > 0}
                  navigate={~p"/games/#{game.id}"}
                  style="background:var(--accent);color:#fff;text-decoration:none;font-size:0.75rem;font-weight:600;padding:0.2rem 0.55rem;border-radius:0.3rem;line-height:1.2"
                >Ask</.link>
                <span
                  :if={Map.get(@source_counts, game.id, 0) == 0}
                  style="display:inline-block;visibility:hidden;font-size:0.75rem;font-weight:600;padding:0.2rem 0.55rem;line-height:1.2"
                >Ask</span>
                <% in_collection = MapSet.member?(@collection_ids, game.id) %>
                <button
                  type="button"
                  phx-click="toggle_collection"
                  phx-value-id={game.id}
                  title={if in_collection, do: "Remove from your collection", else: "Add to your collection"}
                  style={"background:#{if in_collection, do: "color-mix(in srgb,var(--accent) 14%,transparent)", else: "var(--bg-subtle)"};color:#{if in_collection, do: "var(--accent)", else: "var(--text-muted)"};border:1px solid var(--border);font-size:0.75rem;font-weight:600;cursor:pointer;padding:0.2rem 0.45rem;border-radius:0.3rem;line-height:1.2"}
                >{if in_collection, do: "★", else: "☆"}</button>
                <.link
                  :if={RuleMaven.Users.game_master?(@current_user)}
                  navigate={~p"/games/#{game.id}/edit"}
                  style="background:var(--bg-subtle);color:var(--text-secondary);text-decoration:none;font-size:0.75rem;font-weight:600;padding:0.2rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border);line-height:1.2"
                >Edit</.link>
                <%= if RuleMaven.Users.game_master?(@current_user) do %>
                  <%= if @delete_id == game.id do %>
                    <span class="text-xs" style="color:var(--red);padding:0.2rem 0">Delete?</span>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={game.id}
                      style="background:var(--red-bg);color:var(--red);border:1px solid var(--red);font-size:0.7rem;font-weight:600;cursor:pointer;padding:0.2rem 0.4rem;border-radius:0.3rem"
                    >Yes</button>
                    <button
                      type="button"
                      phx-click="cancel_delete"
                      style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);font-size:0.7rem;cursor:pointer;padding:0.2rem 0.4rem;border-radius:0.3rem"
                    >No</button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="delete_game"
                      phx-value-id={game.id}
                      style="color:var(--text-muted);background:var(--bg-subtle);border:1px solid var(--border);font-size:0.7rem;cursor:pointer;padding:0.2rem 0.45rem;border-radius:0.3rem"
                      title="Delete game"
                    >✕</button>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%= if expanded && expansion_count > 0 do %>
              <% expansions =
                if RuleMaven.Users.game_master?(@current_user),
                  do: Games.expansions_for(game),
                  else: Games.expansions_with_documents(game) %>
              <%= for exp <- expansions do %>
                <div
                  id={"exp-card-#{game.id}-#{exp.id}"}
                  class="border rounded-lg p-4 flex items-center gap-4 game-card"
                  phx-click="go_to_game"
                  phx-value-id={exp.id}
                  style={"cursor:pointer;margin-left:2rem;border-left:3px solid var(--accent);#{if @selected_idx == idx, do: "background:var(--bg-subtle)", else: ""}"}
                >
                  <%= if exp.image_url do %>
                    <img
                      src={exp.image_url}
                      alt={exp.name}
                      style="width:40px;height:40px;object-fit:cover;border-radius:0.25rem;flex-shrink:0;pointer-events:none"
                    />
                  <% end %>
                  <div class="flex-1 min-w-0" style="pointer-events:none">
                    <h2 class="text-base font-semibold">{exp.name}</h2>
                    <p class="text-xs text-gray-500">
                      Expansion
                      <%= if exp.year_published do %>
                        &middot; {exp.year_published}
                      <% end %>
                    </p>
                  </div>
                  <div class="flex gap-1.5 flex-shrink-0 game-actions items-center">
                    <a
                      :if={exp.bgg_id && RuleMaven.Games.Category.bgg_relevant?(exp.category)}
                      id={"bgg-link-exp-#{exp.id}"}
                      href={"https://boardgamegeek.com/boardgame/#{exp.bgg_id}"}
                      target="_blank"
                      rel="noopener"
                      phx-hook="ExternalLink"
                      style="background:var(--bg-subtle);color:#ea580c;text-decoration:none;font-size:0.7rem;font-weight:600;cursor:pointer;padding:0.15rem 0.4rem;border-radius:0.3rem;border:1px solid var(--border);line-height:1.2"
                    >BGG</a>
                    <.link
                      :if={Map.get(@source_counts, exp.id, 0) > 0}
                      navigate={~p"/games/#{exp.id}"}
                      style="background:var(--accent);color:#fff;text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.45rem;border-radius:0.3rem;line-height:1.2"
                    >Ask</.link>
                    <span
                      :if={Map.get(@source_counts, exp.id, 0) == 0}
                      style="display:inline-block;visibility:hidden;font-size:0.7rem;font-weight:600;padding:0.15rem 0.45rem;line-height:1.2"
                    >Ask</span>
                    <.link
                      :if={RuleMaven.Users.game_master?(@current_user)}
                      navigate={~p"/games/#{exp.id}/edit"}
                      style="background:var(--bg-subtle);color:var(--text-secondary);text-decoration:none;font-size:0.7rem;font-weight:600;padding:0.15rem 0.4rem;border-radius:0.3rem;border:1px solid var(--border);line-height:1.2"
                    >Edit</.link>
                    <%= if RuleMaven.Users.game_master?(@current_user) do %>
                      <%= if @delete_id == exp.id do %>
                        <span class="text-xs" style="color:var(--red);padding:0.2rem 0">Delete?</span>
                        <button
                          type="button"
                          phx-click="confirm_delete"
                          phx-value-id={exp.id}
                          style="background:var(--red-bg);color:var(--red);border:1px solid var(--red);font-size:0.7rem;font-weight:600;cursor:pointer;padding:0.15rem 0.35rem;border-radius:0.3rem"
                        >Yes</button>
                        <button
                          type="button"
                          phx-click="cancel_delete"
                          style="background:var(--bg-subtle);color:var(--text-secondary);border:1px solid var(--border);font-size:0.7rem;cursor:pointer;padding:0.15rem 0.35rem;border-radius:0.3rem"
                        >No</button>
                      <% else %>
                        <button
                          type="button"
                          phx-click="delete_game"
                          phx-value-id={exp.id}
                          style="color:var(--text-muted);background:var(--bg-subtle);border:1px solid var(--border);font-size:0.7rem;cursor:pointer;padding:0.15rem 0.4rem;border-radius:0.3rem"
                          title="Delete expansion"
                        >✕</button>
                      <% end %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>

        <%!-- Infinite scroll sentinel --%>
        <div
          :if={length(display_games) < length(filtered)}
          id="load-more-sentinel"
          phx-hook="InfiniteScroll"
          style="height:1px"
        >
        </div>

        <p
          :if={length(display_games) < length(filtered)}
          class="text-center text-xs text-gray-400 py-2"
        >
          Showing {length(display_games)} of {length(filtered)}
        </p>

        <%= if @games == [] do %>
          <div class="text-center py-12 text-gray-500" style="max-width:24rem;margin:0 auto">
            <div style="font-size:2rem;margin-bottom:0.75rem">📚</div>
            <p style="font-size:1.05rem;font-weight:600;color:var(--text);margin-bottom:0.5rem">
              Welcome to Rule Maven
            </p>
            <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:0.25rem;line-height:1.5">
              Ask rulebook questions in plain English and get answers with exact citations.
            </p>
            <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1rem;line-height:1.5">
              Add a game or rulebook below to get started.
            </p>
            <div style="display:flex;gap:0.5rem;justify-content:center;flex-wrap:wrap">
              <.link
                navigate={~p"/games/new"}
                style="background:var(--accent);color:#fff;text-decoration:none;font-size:0.8rem;font-weight:600;padding:0.4rem 1rem;border-radius:0.4rem"
              >+ Add manually</.link>
              <.link
                navigate={~p"/games/import"}
                style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);text-decoration:none;font-size:0.8rem;font-weight:600;padding:0.4rem 1rem;border-radius:0.4rem"
              >🔍 Import from BGG</.link>
            </div>
          </div>
        <% end %>

        <%= if @games != [] && filtered_games(@games, @search, @category_filter) == [] do %>
          <div class="text-center py-12 text-gray-500">
            <%= if @category_filter do %>
              <p class="text-lg">No games match "{@search}" in this category</p>
            <% else %>
              <p class="text-lg">No games match "{@search}"</p>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
