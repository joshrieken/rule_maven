defmodule RuleMavenWeb.GameLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, BGG}

  @impl true
  def mount(_params, _session, socket) do
    games =
      if RuleMaven.Users.game_master?(socket.assigns.current_user) do
        Games.list_base_games()
      else
        Games.list_games_with_documents()
      end

    # Preload expansion counts for rendering
    expansion_counts =
      Enum.reduce(games, %{}, fn game, acc ->
        count = length(Games.expansions_with_documents(game))
        Map.put(acc, game.id, count)
      end)

    {:ok,
     assign(socket,
       games: games,
       expansion_counts: expansion_counts,
       confirm_clear: false,
       confirm_text: "",
       search: "",
       refreshing: 0,
       refresh_total: 0,
       refresh_log: [],
       delete_id: nil,
       page: 1,
       per_page: 20,
       selected_idx: -1,
       display_count: 20,
       expanded_games: %{}
     )}
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
  def handle_event("refresh_all", _params, socket) do
    games = socket.assigns.games |> Enum.filter(& &1.bgg_id)
    pid = self()

    Task.start(fn ->
      Enum.with_index(games, 1)
      |> Enum.each(fn {game, i} ->
        send(pid, {:refresh_progress, game.name, i, length(games)})

        case BGG.enrich_game(game) do
          {:ok, _} -> send(pid, {:refresh_done, game.name, :ok})
          {:error, _} -> send(pid, {:refresh_done, game.name, :error})
        end

        :timer.sleep(3000)
      end)

      send(pid, {:refresh_complete})
    end)

    {:noreply, assign(socket, refreshing: 0, refresh_total: length(games), refresh_log: [])}
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
        games = load_games(socket)

        {:noreply,
         socket
         |> assign(games: games, delete_id: nil)
         |> put_flash(:info, "Deleted #{game.name}.")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete #{game.name}.")}
    end
  end

  @impl true
  def handle_event("go_to_game", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/games/#{id}")}
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
          {:noreply, push_navigate(socket, to: ~p"/games/#{game.id}")}
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
    {:noreply, assign(socket, search: text, display_count: 20, selected_idx: -1)}
  end

  @impl true
  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(search: "", display_count: 20, selected_idx: -1)
     |> push_event("refocus", %{})}
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

  defp visible_games(assigns) do
    filtered = filtered_games(assigns.games, assigns.search)
    Enum.take(filtered, assigns.display_count)
  end

  defp load_games(socket) do
    if RuleMaven.Users.game_master?(socket.assigns.current_user) do
      Games.list_games()
    else
      Games.list_games_with_documents()
    end
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @impl true
  def handle_info({:refresh_progress, name, current, total}, socket) do
    log = ["Fetching #{name} (#{current}/#{total})..." | socket.assigns.refresh_log]
    {:noreply, assign(socket, refreshing: current, refresh_total: total, refresh_log: log)}
  end

  @impl true
  def handle_info({:refresh_done, name, status}, socket) do
    icon = if status == :ok, do: "✓", else: "✗"
    log = [icon <> " " <> name | tl(socket.assigns.refresh_log)]
    {:noreply, assign(socket, refresh_log: log)}
  end

  @impl true
  def handle_info({:refresh_complete}, socket) do
    games = load_games(socket)

    {:noreply,
     socket
     |> assign(games: games, refreshing: 0, refresh_total: 0)
     |> put_flash(:info, "Refresh complete!")}
  end

  defp filtered_games(games, ""), do: games

  defp filtered_games(games, search) do
    search = String.downcase(search)

    Enum.filter(games, fn g ->
      String.contains?(String.downcase(g.name), search)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-list">
      <h1 class="text-2xl font-bold mb-4">Rule Maven</h1>

      <form phx-change="search" phx-submit="search" class="mb-4">
        <label class="block text-xs text-gray-400 mb-1">Search</label>
        <div style="position:relative">
          <input
            type="text"
            id="game-search"
            name="search"
            value={@search}
            placeholder="Filter by name..."
            class="w-full border rounded px-3 py-2 pr-8 text-sm"
            autocomplete="off"
            phx-hook="Refocus"
          />
          <button
            :if={@search != ""}
            type="button"
            phx-click="clear_search"
            style="position:absolute;right:0.5rem;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--text-muted);font-size:0.85rem;cursor:pointer;padding:0.25rem;line-height:1"
          >✕</button>
        </div>
      </form>

      <div :if={RuleMaven.Users.game_master?(@current_user)} class="mb-4 flex gap-2 flex-wrap">
        <.button variant="primary" navigate={~p"/games/new"}>+ Add Game</.button>
        <.button variant="secondary" navigate={~p"/games/import"}>Import from BGG</.button>

        <%= if @games != [] do %>
          <button
            type="button"
            phx-click="refresh_all"
            style="background:var(--accent);color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
          >
            Refresh All from BGG
          </button>

          <%= if not @confirm_clear do %>
            <button
              type="button"
              phx-click="confirm_clear"
              style="background:#dc2626;color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
            >
              Clear All Games
            </button>
          <% else %>
            <form phx-change="confirm_input" style="display:inline">
              <span class="text-sm font-medium" style="color:#dc2626">Type DELETE to confirm:</span>
              <input
                type="text"
                name="confirm_text"
                value={@confirm_text}
                placeholder="DELETE"
                style="border:1px solid #dc2626;border-radius:0.375rem;padding:0.25rem 0.5rem;font-size:0.8rem;width:6rem"
              />
            </form>
            <button
              type="button"
              phx-click="clear_all_games"
              disabled={@confirm_text != "DELETE"}
              style="background:#dc2626;color:white;border:none;padding:0.375rem 0.75rem;border-radius:0.375rem;font-weight:600;font-size:0.8rem;cursor:pointer"
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

      <%= if @refresh_total > 0 do %>
        <div class="mb-4 border rounded-lg p-3">
          <div style="width:100%;height:4px;background:var(--border);border-radius:2px;margin-bottom:0.5rem">
            <div style={"width:#{trunc(@refreshing / @refresh_total * 100)}%;height:100%;background:var(--accent);border-radius:2px;transition:width 0.3s"}>
            </div>
          </div>
          <div class="max-h-24 overflow-y-auto space-y-0.5">
            <%= for entry <- Enum.reverse(@refresh_log) |> Enum.take(5) do %>
              <p class="text-xs text-gray-500">{entry}</p>
            <% end %>
          </div>
        </div>
      <% end %>

      <% filtered = filtered_games(@games, @search) %>
      <% display_games = visible_games(assigns) %>

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
                {length(Games.list_rulebook_sources(game))} source(s)
                <%= if game.year_published do %>
                  &middot; {game.year_published}
                <% end %>
                <%= if game.min_players do %>
                  &middot; {game.min_players}-{game.max_players}p
                <% end %>
                <%= if game.playing_time do %>
                  &middot; ~{game.playing_time}m
                <% end %>
                <%= if expansion_count > 0 do %>
                  &middot; <span style="color:var(--accent);font-weight:600">{expansion_count} expansion(s)</span>
                <% end %>
              </p>
            </div>
            <div class="flex gap-2 flex-shrink-0 game-actions items-center">
              <%= if expansion_count > 0 do %>
                <button
                  type="button"
                  phx-click="toggle_expansions"
                  phx-value-id={game.id}
                  style="color:var(--blue);background:none;border:none;font-size:0.8rem;font-weight:600;cursor:pointer;padding:0.1rem 0.3rem"
                >{if expanded, do: "▲", else: "▼"}</button>
              <% end %>
              <a
                :if={game.bgg_id}
                id={"bgg-link-#{game.id}"}
                href={"https://boardgamegeek.com/boardgame/#{game.bgg_id}"}
                target="_blank"
                rel="noopener"
                phx-hook="ExternalLink"
                style="color:#ea580c;text-decoration:none;font-size:0.8rem;font-weight:600;cursor:pointer"
              >BGG</a>
              <.link
                navigate={~p"/games/#{game.id}"}
                class="text-blue-600 hover:underline text-sm font-medium"
              >Ask</.link>
              <.link
                :if={RuleMaven.Users.game_master?(@current_user)}
                navigate={~p"/games/#{game.id}/edit"}
                class="text-gray-600 hover:underline text-sm"
              >Edit</.link>
            </div>

            <%= if RuleMaven.Users.game_master?(@current_user) do %>
              <div class="flex-shrink-0">
                <%= if @delete_id == game.id do %>
                  <div class="flex items-center gap-1">
                    <span class="text-xs" style="color:#dc2626">Delete?</span>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={game.id}
                      style="color:#dc2626;background:none;border:none;font-size:0.75rem;font-weight:600;cursor:pointer"
                    >Yes</button>
                    <button
                      type="button"
                      phx-click="cancel_delete"
                      style="color:var(--text-secondary);background:none;border:none;font-size:0.75rem;cursor:pointer"
                    >No</button>
                  </div>
                <% else %>
                  <button
                    type="button"
                    phx-click="delete_game"
                    phx-value-id={game.id}
                    style="color:var(--text-muted);background:none;border:none;font-size:0.75rem;cursor:pointer;padding:0.25rem"
                    title="Delete game"
                  >✕</button>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if expanded && expansion_count > 0 do %>
            <% expansions = Games.expansions_with_documents(game) %>
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
                <div class="flex gap-2 flex-shrink-0 game-actions items-center">
                  <a
                    :if={exp.bgg_id}
                    id={"bgg-link-exp-#{exp.id}"}
                    href={"https://boardgamegeek.com/boardgame/#{exp.bgg_id}"}
                    target="_blank"
                    rel="noopener"
                    phx-hook="ExternalLink"
                    style="color:#ea580c;text-decoration:none;font-size:0.75rem;font-weight:600;cursor:pointer"
                  >BGG</a>
                  <.link
                    navigate={~p"/games/#{exp.id}"}
                    class="text-blue-600 hover:underline text-sm font-medium"
                  >Ask</.link>
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

      <p :if={length(display_games) < length(filtered)} class="text-center text-xs text-gray-400 py-2">
        Showing {length(display_games)} of {length(filtered)}
      </p>

      <%= if @games == [] do %>
        <div class="text-center py-12 text-gray-500">
          <p class="text-lg">No games yet.</p>
          <p>Add a game to get started!</p>
        </div>
      <% end %>

      <%= if @games != [] && filtered_games(@games, @search) == [] do %>
        <div class="text-center py-12 text-gray-500">
          <p class="text-lg">No games match "{@search}"</p>
        </div>
      <% end %>
    </div>
    """
  end
end
