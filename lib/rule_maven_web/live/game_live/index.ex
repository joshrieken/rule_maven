defmodule RuleMavenWeb.GameLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    collection_ids = Games.collection_game_ids(user_id)
    favorite_ids = Games.favorite_game_ids(user_id)

    # Default landing view: askable games (those with rulebooks). Users can
    # toggle to their collection or browse the full catalog. The last-used view
    # is remembered per-browser and delivered via the LiveSocket connect params,
    # which only exist on the connected mount. The disconnected (SSR) mount has
    # no view yet — render nothing there so the static HTML doesn't flash the
    # default before the remembered selection arrives on connect.
    view = if connected?(socket), do: restore_view(socket), else: nil
    games = if view, do: load_view_games(view, user_id, "", nil), else: []

    socket =
      socket
      |> assign(
        view: view,
        collection_ids: collection_ids,
        favorite_ids: favorite_ids,
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
        category_filter: nil
      )
      |> assign_games(games)

    {:ok, socket}
  end

  @views ~w(playable mine favorites all)

  # Views available to a user. "All Games" (full catalog) is game-master only;
  # players are limited to playable games, their collection, and favorites.
  defp view_tabs(user) do
    base = [{"playable", "Playable"}, {"mine", "My Collection"}, {"favorites", "Favorites"}]
    if RuleMaven.Users.game_master?(user), do: base ++ [{"all", "All Games"}], else: base
  end

  defp allowed_view?(user, view) do
    view in ~w(playable mine favorites) or (view == "all" and RuleMaven.Users.game_master?(user))
  end

  # Friendly, view-specific copy shown when a pill has no games to list.
  defp empty_state("playable"),
    do: %{
      icon: "🎲",
      title: "No playable games yet",
      body: "Games show up here once they have a rulebook. Import your collection to get going."
    }

  defp empty_state("mine"),
    do: %{
      icon: "📦",
      title: "Your collection is empty",
      body: "Sync your BoardGameGeek collection to fill it with the games you own."
    }

  defp empty_state("favorites"),
    do: %{
      icon: "💛",
      title: "No favorites yet",
      body: "Tap the ♡ on any game to save it here for quick access."
    }

  defp empty_state("all"),
    do: %{
      icon: "🗂️",
      title: "The catalog is empty",
      body: "Add a game or import a BoardGameGeek collection to seed the catalog."
    }

  defp empty_state(_),
    do: %{icon: "📚", title: "Nothing here yet", body: "Pick a view above to browse games."}

  # Restore the remembered view from the localStorage-backed connect param.
  # Returns "playable" on the disconnected mount, an unknown value, or a view
  # the user isn't allowed (e.g. a stale "all" pref after losing access).
  defp restore_view(socket) do
    user = socket.assigns.current_user

    case get_connect_params(socket) do
      %{"list_view" => v} when v in @views ->
        if allowed_view?(user, v), do: v, else: "playable"

      _ ->
        "playable"
    end
  end

  # Load the game list for a view. "all" is DB-backed (catalog can be huge), so
  # it pages from the database with a growing limit; "mine"/"playable"/"favorites"
  # are bounded lists loaded fully and paginated in-memory by the render path.
  defp load_view_games(view, user_id, search, category, limit \\ 20)

  defp load_view_games("mine", user_id, _search, _category, _limit),
    do: Games.list_collection(user_id)

  defp load_view_games("favorites", user_id, _search, _category, _limit),
    do: Games.list_favorites(user_id)

  defp load_view_games("all", _user_id, search, category, limit),
    # Fetch one extra row so the render path can tell there's more to page in
    # (the infinite-scroll sentinel shows while display_games < loaded games).
    do: Games.search_catalog(search || "", category: category, limit: limit + 1)

  defp load_view_games(_playable, _user_id, _search, _category, _limit),
    do: Games.list_games_with_documents()

  # Assign the current games plus their expansion/source counts. Counts are
  # computed only for the games actually visible (display_count), in a couple of
  # batched aggregate queries, so this stays cheap even on a 150k catalog.
  defp assign_games(socket, games) do
    socket = assign(socket, games: games)
    is_admin = RuleMaven.Users.game_master?(socket.assigns.current_user)

    visible_ids = socket.assigns |> visible_games() |> Enum.map(& &1.id)

    expansion_counts =
      if is_admin,
        do: Games.expansion_counts(visible_ids),
        else: Games.expansion_with_doc_counts(visible_ids)

    source_counts = Games.document_counts(visible_ids)

    assign(socket, expansion_counts: expansion_counts, source_counts: source_counts)
  end

  # Reload the games for the current view/search/category and recompute counts.
  defp reload_games(socket) do
    %{view: view, search: search, category_filter: category, display_count: limit} =
      socket.assigns

    games =
      load_view_games(view, socket.assigns.current_user.id, search || "", category, limit)

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
  def handle_event("set_view", %{"view" => view}, socket) when view in @views do
    if allowed_view?(socket.assigns.current_user, view) do
      {:noreply,
       socket
       |> assign(view: view, display_count: 20, selected_idx: -1)
       |> reload_games()
       |> push_event("save_view", %{view: view})}
    else
      {:noreply, socket}
    end
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
  def handle_event("toggle_favorite", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user_id = socket.assigns.current_user.id

    if MapSet.member?(socket.assigns.favorite_ids, id) do
      Games.remove_favorite(user_id, id)
    else
      Games.add_favorite(user_id, id)
    end

    favorite_ids = Games.favorite_game_ids(user_id)
    socket = assign(socket, favorite_ids: favorite_ids)
    # Reflect the change immediately when viewing favorites.
    socket = if socket.assigns.view == "favorites", do: reload_games(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    socket = assign(socket, display_count: socket.assigns.display_count + 20)
    # The "all" view pages from the DB, so fetch the next page; other views are
    # already fully loaded and just reveal more rows in-memory.
    socket = if socket.assigns.view == "all", do: reload_games(socket), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_all_games", _params, socket) do
    {count, _} = Games.delete_all_games()

    {:noreply,
     socket
     |> assign(games: [], confirm_clear: false, confirm_text: "", search: "")
     |> put_flash(:info, "Cleared #{count} game(s).")}
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

      <div class="mb-4 flex gap-2 flex-wrap" id="view-tabs" phx-hook="ViewPref">
        <%= for {key, label} <- view_tabs(@current_user) do %>
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

      <div class="mb-4 flex gap-2 flex-wrap">
        <.button
          :if={RuleMaven.Users.game_master?(@current_user)}
          variant="primary"
          navigate={~p"/games/new"}
        >+ Add Game</.button>
        <.button variant="secondary" navigate={~p"/games/import"}>Import BGG Collection</.button>
      </div>

      <%!-- Danger Zone --%>
      <div
        :if={RuleMaven.Users.game_master?(@current_user) and @games != []}
        style="margin-bottom:1rem;border:1px solid var(--red);border-radius:0.5rem;padding:0.75rem 0.9rem;background:var(--bg)"
      >
        <h3 style="font-size:0.78rem;font-weight:700;color:var(--red);margin:0 0 0.5rem 0;text-transform:uppercase;letter-spacing:0.03em">
          Danger Zone
        </h3>
        <div class="flex gap-2 flex-wrap" style="align-items:center">
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
        </div>
      </div>

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
                <% favorited = MapSet.member?(@favorite_ids, game.id) %>
                <button
                  type="button"
                  phx-click="toggle_collection"
                  phx-value-id={game.id}
                  title={if in_collection, do: "Remove from your collection", else: "Add to your collection"}
                  style={"background:#{if in_collection, do: "color-mix(in srgb,var(--accent) 14%,transparent)", else: "var(--bg-subtle)"};color:#{if in_collection, do: "var(--accent)", else: "var(--text-muted)"};border:1px solid var(--border);font-size:0.75rem;font-weight:600;cursor:pointer;padding:0.2rem 0.45rem;border-radius:0.3rem;line-height:1.2"}
                >{if in_collection, do: "★", else: "☆"}</button>
                <button
                  type="button"
                  phx-click="toggle_favorite"
                  phx-value-id={game.id}
                  title={if favorited, do: "Remove from favorites", else: "Add to favorites"}
                  style={"background:#{if favorited, do: "color-mix(in srgb,var(--red) 14%,transparent)", else: "var(--bg-subtle)"};color:#{if favorited, do: "var(--red)", else: "var(--text-muted)"};border:1px solid var(--border);font-size:0.75rem;font-weight:600;cursor:pointer;padding:0.2rem 0.45rem;border-radius:0.3rem;line-height:1.2"}
                >{if favorited, do: "♥", else: "♡"}</button>
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

        <%= if @games == [] and @view != nil do %>
          <% es = empty_state(@view) %>
          <div class="text-center py-12 text-gray-500" style="max-width:22rem;margin:0 auto">
            <div style="font-size:1.75rem;margin-bottom:0.6rem">{es.icon}</div>
            <p style="font-size:1rem;font-weight:600;color:var(--text);margin-bottom:0.35rem">
              {es.title}
            </p>
            <p style="font-size:0.82rem;color:var(--text-muted);line-height:1.5;margin-bottom:1rem">
              {es.body}
            </p>
            <.link
              :if={@view in ~w(mine playable all)}
              navigate={~p"/games/import"}
              style="background:var(--accent);color:#fff;text-decoration:none;font-size:0.8rem;font-weight:600;padding:0.4rem 1rem;border-radius:0.4rem"
            >🔍 Import BGG Collection</.link>
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
