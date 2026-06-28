defmodule RuleMavenWeb.GameLive.Import do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{BGG, Games}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       username: "",
       results: nil,
       loading: false,
       error: nil,
       imported: [],
       importing: false,
       import_total: 0,
       import_count: 0
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Any authenticated user may sync their own BGG collection. Imported games
    # are upserted into the shared catalog and added to the user's collection;
    # this is not game authoring, which stays admin only (see Form).
    {:noreply, socket}
  end

  @impl true
  def handle_event("fetch", %{"username" => username}, socket) do
    username = String.trim(username)

    if username == "" do
      {:noreply, assign(socket, error: "Enter a BGG username")}
    else
      socket =
        assign(socket,
          username: username,
          loading: true,
          error: nil,
          results: nil
        )

      send(self(), {:fetch_collection, username})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("import", _params, socket) do
    %{results: results, imported: imported} = socket.assigns
    existing_bgg_ids = Games.collection_bgg_ids(socket.assigns.current_user.id)

    to_import =
      results
      |> Enum.reject(fn g -> g.bgg_id in existing_bgg_ids or g.bgg_id in imported end)

    if to_import == [] do
      {:noreply, socket}
    else
      socket =
        assign(socket,
          importing: true,
          import_total: length(to_import),
          import_count: 0
        )

      send(self(), {:import_games, to_import, imported, []})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:import_games, [game | rest], imported, created}, socket) do
    user_id = socket.assigns.current_user.id

    {new_imported, new_created} =
      case ensure_catalog_game(game) do
        {:ok, db_game, was_created} ->
          Games.add_to_collection(user_id, db_game.id)
          {imported ++ [game.bgg_id], if(was_created, do: [db_game | created], else: created)}

        :error ->
          {imported, created}
      end

    count = socket.assigns.import_count + 1

    send(self(), {:import_games, rest, new_imported, new_created})

    {:noreply,
     assign(socket,
       imported: new_imported,
       import_count: count
     )}
  end

  @impl true
  def handle_info({:import_games, [], imported, _created}, socket) do
    # Imported games are NOT enriched from BGG here. Unsupported games sit in the
    # user's collection grayed out until someone adds rulebook support; metadata
    # is pulled later (on demand, in the game form) only for games we support.
    {:noreply,
     assign(socket,
       importing: false,
       imported: imported
     )}
  end

  @impl true
  def handle_info({:fetch_collection, username}, socket) do
    # Requests carry the app's configured BGG API token (see BGG.build_headers),
    # so no per-user credentials or login are needed — we read the user's public
    # collection by username.
    do_fetch(socket, username, nil)
  end

  # Find the game in the global catalog by BGG id, or create it. Returns
  # {:ok, game, was_created?} so callers can enrich only freshly-created rows.
  defp ensure_catalog_game(%{bgg_id: bgg_id} = attrs) do
    case Games.get_game_by_bgg_id(bgg_id) do
      nil ->
        # Seed lightweight metadata from the collection response (one request,
        # no per-game BGG calls). The rank dump later upserts by bgg_id and stays
        # authoritative for name/year/rank, so this won't conflict.
        create_attrs = %{
          name: attrs.name,
          bgg_id: bgg_id,
          year_published: attrs[:year_published],
          image_url: attrs[:image_url],
          min_players: attrs[:min_players],
          max_players: attrs[:max_players],
          playing_time: attrs[:playing_time]
        }

        case Games.create_game(create_attrs) do
          {:ok, game} -> {:ok, game, true}
          _ -> :error
        end

      game ->
        {:ok, game, false}
    end
  end

  defp do_fetch(socket, username, cookies) do
    case BGG.fetch_collection(username, cookies: cookies) do
      {:ok, games} ->
        existing_bgg_ids = Games.collection_bgg_ids(socket.assigns.current_user.id)

        {already, new_games} =
          games
          |> Enum.sort_by(& &1.name)
          |> Enum.split_with(fn g -> g.bgg_id in existing_bgg_ids end)

        {:noreply,
         assign(socket,
           results: new_games ++ already,
           existing_bgg_ids: existing_bgg_ids,
           loading: false,
           imported: []
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           error: reason,
           loading: false,
           results: nil
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="import-page">
      <div class="mb-4">
        <.link navigate={~p"/"} class="back-link">
          &larr; Back to games
        </.link>
      </div>

      <h1 class="text-2xl font-bold mb-6">Sync Your BGG Collection</h1>

      <div class="border rounded-lg p-4 mb-6">
        <form phx-submit="fetch" class="space-y-3">
          <div>
            <label class="block text-sm font-medium mb-1">BGG Username</label>
            <input
              type="text"
              name="username"
              value={@username}
              placeholder="Whose collection to import..."
              class="w-full border rounded px-3 py-2"
              disabled={@loading}
              required
            />
          </div>

          <p class="text-xs text-gray-400">
            Your BGG collection must be public to import. We never ask for
            your BoardGameGeek password.
          </p>

          <button
            type="submit"
            class="btn btn-primary"
            disabled={@loading}
            style="background:var(--accent);color:white;border:none;padding:0.5rem 1rem;border-radius:0.375rem;font-weight:600;cursor:pointer"
          >
            {if @loading, do: "Fetching...", else: "Fetch Collection"}
          </button>
        </form>
      </div>

      <%= if @loading do %>
        <div class="border rounded-lg p-4 mb-6 bg-gray-50 text-gray-500 animate-pulse">
          Fetching collection from BGG...
        </div>
      <% end %>

      <%= if @error do %>
        <div class="alert alert-error mb-6">
          <span>{@error}</span>
        </div>
      <% end %>

      <%= if @results do %>
        <div class="mb-4 flex items-center justify-between">
          <p class="text-sm text-gray-500">
            Found {length(@results)} games. {length(@imported)} imported this session.
          </p>
          <button
            :if={length(@results) > 0}
            type="button"
            phx-click="import"
            disabled={@importing}
            class="btn"
            style="background:var(--accent);color:white;border:none;padding:0.5rem 1rem;border-radius:0.375rem;font-weight:600;cursor:pointer"
          >
            Import All New
          </button>
        </div>

        <%= if @importing do %>
          <div class="mb-4">
            <div style="width:100%;height:4px;background:var(--border);border-radius:2px">
              <div style={"width:#{trunc(@import_count / @import_total * 100)}%;height:100%;background:var(--accent);border-radius:2px;transition:width 0.2s"}>
              </div>
            </div>
            <p class="text-xs text-gray-500 mt-1">
              Importing {@import_count} of {@import_total}...
            </p>
          </div>
        <% end %>

        <div class="space-y-2">
          <%= for game <- @results do %>
            <div class="border rounded-lg p-3 flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="text-sm font-medium">{game.name}</span>
                <a
                  href={"https://boardgamegeek.com/boardgame/#{game.bgg_id}"}
                  target="_blank"
                  rel="noopener"
                  class="text-xs text-blue-500 hover:underline"
                >
                  BGG
                </a>
              </div>
              <div>
                <%= cond do %>
                  <% game.bgg_id in @existing_bgg_ids -> %>
                    <span
                      class="text-xs px-2 py-1 rounded"
                      style="background:var(--bg-subtle);color:var(--text-secondary)"
                    >
                      In your collection
                    </span>
                  <% game.bgg_id in @imported -> %>
                    <span class="text-xs px-2 py-1 rounded badge-green">
                      Imported
                    </span>
                  <% true -> %>
                    <span
                      class="text-xs px-2 py-1 rounded"
                      style="background:var(--bg-surface);color:var(--text-muted)"
                    >
                      New
                    </span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
