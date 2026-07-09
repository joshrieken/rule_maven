defmodule RuleMavenWeb.GameLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games
  alias RuleMaven.Settings

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
        requested_ids: Games.requested_game_ids(socket.assigns.current_user.id),
        search: if(connected?(socket), do: nil, else: ""),
        search_ready: false,
        page: 1,
        per_page: 20,
        selected_idx: -1,
        display_count: 20,
        expanded_games: %{},
        # game_id => {done, total} while an expansion BGG sync is in flight.
        expansion_sync: %{},
        exp_sync_subscribed: MapSet.new(),
        # game_ids with a BGG "Pull" in flight (drives the per-row spinner).
        bgg_pulling: MapSet.new(),
        category_filter: nil,
        # First-ever visit → the Tour hook auto-starts the games tour.
        tour_autostart: RuleMavenWeb.Tours.autostart?(socket, "games"),
        # Date-seeded, so the static and connected mounts render the same card.
        rule_of_day: RuleMaven.RuleOfTheDay.pick()
      )
      |> assign_games(games)
      |> resume_exp_syncs()
      |> resume_bgg_pulls()

    {:ok, socket}
  end

  # Rediscover expansion BGG syncs still running (the detached Task persists
  # "exp_sync:<id>" => "done/total" in Settings), so a refresh/remount re-shows
  # progress and re-subscribes for live updates instead of going dark.
  defp resume_exp_syncs(socket) do
    if connected?(socket) do
      active =
        Settings.all()
        |> Enum.flat_map(fn {k, v} ->
          case Regex.run(~r/^exp_sync:(\d+)$/, k) do
            [_, id] -> [{String.to_integer(id), parse_progress(v)}]
            _ -> []
          end
        end)

      Enum.each(active, fn {id, _} ->
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, exp_sync_topic(id))
      end)

      ids = Enum.map(active, &elem(&1, 0))

      assign(socket,
        expansion_sync: Map.new(active),
        exp_sync_subscribed: MapSet.new(ids),
        expanded_games: Enum.reduce(ids, socket.assigns.expanded_games, &Map.put(&2, &1, true))
      )
    else
      socket
    end
  end

  # Re-seed the "Pulling…" indicator from in-flight Oban jobs after a remount, so
  # the spinner survives navigation instead of going dark mid-pull.
  defp resume_bgg_pulls(socket) do
    if connected?(socket) do
      pulling = RuleMaven.Workers.BggEnrichWorker.running_game_ids()

      Enum.each(pulling, fn id ->
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.Workers.BggEnrichWorker.topic(id))
      end)

      assign(socket, bgg_pulling: pulling)
    else
      socket
    end
  end

  defp parse_progress(v) do
    case String.split(to_string(v), "/") do
      [d, t] -> {String.to_integer(d), String.to_integer(t)}
      _ -> {0, 0}
    end
  end

  @views ~w(playable mine favorites all needs_bgg requested)

  # Views whose rows are paged from the DB (vs fully loaded + paged in-memory).
  defp db_paged?(view), do: view in ~w(all needs_bgg)

  # Views available to a user. "All Games" (full catalog) is admin only;
  # non-admin users are limited to playable games, their collection, and favorites.
  defp view_tabs(user) do
    base = [{"playable", "Ready"}, {"mine", "My Collection"}, {"favorites", "Favorites"}]

    if RuleMaven.Users.can?(user, :admin),
      do:
        [{"all", "All Games"}] ++
          base ++ [{"needs_bgg", "Needs Pull"}, {"requested", "Requested"}],
      else: base
  end

  defp allowed_view?(user, view) do
    view in ~w(playable mine favorites) or
      (view in ~w(all needs_bgg requested) and RuleMaven.Users.can?(user, :admin))
  end

  # Friendly, view-specific copy shown when a pill has no games to list.
  defp empty_state("playable"),
    do: %{
      icon: "🎲",
      title: "No ready games yet",
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

  defp empty_state("needs_bgg"),
    do: %{
      icon: "✅",
      title: "Nothing to pull",
      body: "Every game with a BGG id already has its full BGG data."
    }

  defp empty_state("requested"),
    do: %{
      icon: "🙋",
      title: "No requests yet",
      body: "Games users request support for will show up here."
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

  defp load_view_games("needs_bgg", _user_id, search, category, limit),
    # Fetch one extra row so the render path knows there's another page.
    do: Games.list_games_needing_bgg(search || "", category: category, limit: limit + 1)

  defp load_view_games("requested", _user_id, _search, _category, _limit),
    do: Games.list_requested_games()

  defp load_view_games(_playable, _user_id, _search, _category, _limit),
    do: Games.list_playable_games()

  # Assign the current games plus their expansion/source counts. Counts are
  # computed only for the games actually visible (display_count), in a couple of
  # batched aggregate queries, so this stays cheap even on a 150k catalog.
  defp assign_games(socket, games) do
    socket = assign(socket, games: games)
    is_admin = RuleMaven.Users.can?(socket.assigns.current_user, :admin)

    visible_ids = socket.assigns |> visible_games() |> Enum.map(& &1.id)

    expansion_counts =
      if is_admin,
        do: Games.expansion_counts(visible_ids),
        else: Games.expansion_with_doc_counts(visible_ids)

    source_counts = Games.document_counts(visible_ids)

    # Only admins see the "Pull expansions" button, so skip this query otherwise.
    expansion_pull_counts =
      if is_admin, do: Games.expansion_pull_counts(visible_ids), else: %{}

    assign(socket,
      expansion_counts: expansion_counts,
      source_counts: source_counts,
      expansion_pull_counts: expansion_pull_counts
    )
  end

  # Reload the games for the current view/search/category and recompute counts.
  defp reload_games(socket) do
    %{view: view, search: search, category_filter: category, display_count: limit} =
      socket.assigns

    games =
      load_view_games(view, socket.assigns.current_user.id, search || "", category, limit)

    assign_games(socket, games)
  end

  # DB-paged views must re-query on search/category changes.
  defp maybe_reload_for_all(socket) do
    if db_paged?(socket.assigns.view), do: reload_games(socket), else: socket
  end

  @impl true
  def handle_event("tour_" <> _ = event, params, socket),
    do: RuleMavenWeb.Tours.handle_event(event, params, socket)

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

  # Deletion is confirmed client-side via data-confirm on the "⋯" menu item.
  @impl true
  def handle_event("confirm_delete", %{"id" => id_str}, socket) do
    # This LiveView is in the :default live_session — logged-in, but NOT admin —
    # so the delete menu item being hidden in the template is not a guard at all.
    # LiveView events are forgeable, and this cascades documents and questions.
    # Re-fetch the user rather than trusting a mount-time assign, so a demoted
    # admin can't delete on a still-open socket.
    if admin?(socket) do
      do_confirm_delete(socket, id_str)
    else
      {:noreply, socket}
    end
  end

  defp admin?(socket) do
    RuleMaven.Users.can?(RuleMaven.Users.get_user(socket.assigns.current_user.id), :admin)
  end

  defp do_confirm_delete(socket, id_str) do
    {id, _} = Integer.parse(id_str)
    game = Games.get_game!(id)

    case Games.delete_game(game) do
      {:ok, _} ->
        {:noreply,
         socket
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
    token = RuleMaven.Hashid.encode(id)

    dest =
      if source_count == 0 and RuleMaven.Users.can?(socket.assigns.current_user, :admin),
        do: ~p"/games/#{token}/edit",
        else: ~p"/games/#{token}"

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
            if source_count == 0 and RuleMaven.Users.can?(socket.assigns.current_user, :admin),
              do: ~p"/games/#{game}/edit",
              else: ~p"/games/#{game}"

          {:noreply, push_navigate(socket, to: dest)}
        else
          {:noreply, socket}
        end

      "e" ->
        if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
          idx = socket.assigns.selected_idx

          if idx >= 0 && idx < length(visible) do
            game = Enum.at(visible, idx)
            {:noreply, push_navigate(socket, to: ~p"/games/#{game}/edit")}
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
     |> maybe_reload_for_all()
     |> push_event("reset_list_pos", %{})}
  end

  @impl true
  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(search: "", search_ready: true, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()
     |> push_event("refocus", %{})
     |> push_event("reset_list_pos", %{})}
  end

  @impl true
  def handle_event("restore_search", %{"value" => text}, socket) do
    # Keep display_count untouched: the saved list position is restored
    # separately via "restore_list_pos", and this fires on every mount.
    #
    # Counts (source/expansion) are computed over visible_games, which is empty
    # while search is still nil (the connected-mount sentinel). Now that search
    # is restored, recompute them so the Ask button + expansion toggle appear:
    # "all" re-queries the DB, other views just recompute counts over the
    # already-loaded list.
    socket = assign(socket, search: text, search_ready: true, selected_idx: -1)

    socket =
      if db_paged?(socket.assigns.view),
        do: reload_games(socket),
        else: assign_games(socket, socket.assigns.games)

    {:noreply, socket}
  end

  # Restore how many rows were loaded when the user last left the list, so the
  # saved scroll position (applied client-side) has enough content to land on.
  @impl true
  def handle_event("restore_list_pos", %{"count" => count}, socket) do
    count = count |> max(20) |> min(2000)

    {:noreply,
     socket
     |> assign(display_count: count)
     |> reload_games()}
  end

  @impl true
  def handle_event("set_category_filter", %{"category" => category}, socket) do
    filter = if category == "", do: nil, else: category

    {:noreply,
     socket
     |> assign(category_filter: filter, display_count: 20, selected_idx: -1)
     |> maybe_reload_for_all()
     |> push_event("reset_list_pos", %{})}
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) when view in @views do
    if allowed_view?(socket.assigns.current_user, view) do
      {:noreply,
       socket
       |> assign(view: view, display_count: 20, selected_idx: -1)
       |> reload_games()
       |> push_event("save_view", %{view: view})
       |> push_event("reset_list_pos", %{})}
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
  def handle_event("pull_bgg", %{"id" => id_str}, socket) do
    if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
      {id, _} = Integer.parse(id_str)
      game = Games.get_game!(id)

      # Durable + non-blocking: enqueue the (throttled, retry-prone) BGG pull and
      # refresh when {:bgg_enriched, ...} arrives, instead of blocking the LV.
      if connected?(socket) do
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.Workers.BggEnrichWorker.topic(id))
      end

      %{game_id: id}
      |> RuleMaven.Workers.BggEnrichWorker.new()
      |> Oban.insert()

      {:noreply,
       socket
       |> assign(bgg_pulling: MapSet.put(socket.assigns.bgg_pulling, id))
       |> put_flash(:info, "Pulling BGG data for #{game.name}…")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("pull_expansions", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    cond do
      not RuleMaven.Users.can?(socket.assigns.current_user, :admin) ->
        {:noreply, socket}

      # Already running (button disabled, but guard against a stale/raced click).
      Settings.get(exp_sync_key(id)) != nil ->
        {:noreply, socket}

      true ->
        do_pull_expansions(socket, id)
    end
  end

  @impl true
  def handle_event("request_support", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    Games.request_support(socket.assigns.current_user.id, id)

    {:noreply,
     socket
     |> assign(requested_ids: MapSet.put(socket.assigns.requested_ids, id))
     |> put_flash(:info, "Requested support — we'll take a look.")}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    count = socket.assigns.display_count + 20
    socket = assign(socket, display_count: count)
    # DB-paged views fetch the next page. Other views are already fully loaded,
    # but counts are only computed for the previously visible rows — recompute
    # them so the newly revealed games get their expansion/source counts
    # (otherwise their toggle + Ask button stay hidden).
    socket =
      if db_paged?(socket.assigns.view),
        do: reload_games(socket),
        else: assign_games(socket, socket.assigns.games)

    {:noreply, push_event(socket, "save_count", %{count: count})}
  end

  @impl true
  def handle_info({:bgg_enriched, game_id, :ok}, socket) do
    {:noreply,
     socket
     |> assign(bgg_pulling: MapSet.delete(socket.assigns.bgg_pulling, game_id))
     |> reload_games()
     |> put_flash(:info, "BGG data updated.")}
  end

  def handle_info({:bgg_enriched, game_id, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(bgg_pulling: MapSet.delete(socket.assigns.bgg_pulling, game_id))
     |> put_flash(:error, "BGG pull failed: #{reason}")}
  end

  def handle_info({:expansion_progress, id, done, total}, socket) do
    # Recompute counts (over the already-loaded games) so the "⬇ Exp (n)" button
    # decrements live and the expanded panel re-queries each expansion's freshly
    # pulled BGG data.
    {:noreply,
     socket
     |> assign(expansion_sync: Map.put(socket.assigns.expansion_sync, id, {done, total}))
     |> assign_games(socket.assigns.games)}
  end

  @impl true
  def handle_info({:expansion_sync_done, id}, socket) do
    # Final recompute so the button hits 0 and disappears without a refresh.
    {:noreply,
     socket
     |> assign(expansion_sync: Map.delete(socket.assigns.expansion_sync, id))
     |> assign_games(socket.assigns.games)}
  end

  defp exp_sync_topic(game_id), do: "expansion_sync:#{game_id}"
  defp exp_sync_key(game_id), do: "exp_sync:#{game_id}"

  defp do_pull_expansions(socket, id) do
    game = Games.get_game!(id)
    # Only expansions that actually have a BGG id can be pulled.
    expansions = game |> Games.expansions_for() |> Enum.filter(& &1.bgg_id)
    total = length(expansions)
    topic = exp_sync_topic(id)
    key = exp_sync_key(id)

    # Subscribe once per game so progress broadcast from the background Task
    # drives live re-renders (which re-query each expansion's fresh BGG data).
    socket =
      if connected?(socket) and not MapSet.member?(socket.assigns.exp_sync_subscribed, id) do
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, topic)
        assign(socket, exp_sync_subscribed: MapSet.put(socket.assigns.exp_sync_subscribed, id))
      else
        socket
      end

    # Persist running state so a refresh can rediscover this sync (see
    # resume_exp_syncs/1). The durable Oban worker survives server restarts and
    # drives the same progress broadcasts.
    Settings.put(key, "0/#{total}")
    RuleMaven.Workers.ExpansionSyncWorker.enqueue(id)

    {:noreply,
     socket
     |> assign(
       expanded_games: Map.put(socket.assigns.expanded_games, id, true),
       expansion_sync: Map.put(socket.assigns.expansion_sync, id, {0, total})
     )}
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

  # "⋯" overflow menu holding a card's secondary actions (progressive
  # disclosure: only Ask/Request + favorite stay on the card itself). Uses the
  # app-wide <details class="card-menu"> pattern — app.js already closes it on
  # outside click, opens one at a time, and closes on LV navigation.
  slot :inner_block, required: true

  defp card_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <%!-- stopPropagation: the whole game card is phx-click=go_to_game; opening
            the menu must not also navigate. (Items inside the pop are fine —
            LiveView dispatches only the nearest phx-click.) --%>
      <summary class="card-menu__trigger" title="More actions" onclick="event.stopPropagation()">
        ⋯
      </summary>
      <div class="card-menu__pop card-menu__pop--right">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game-list">
      <%!-- Hosts the spotlight onboarding tour for this page (Hooks.Tour). --%>
      <div
        id="tour-games"
        phx-hook="Tour"
        data-tour-page="games"
        data-tour-autostart={@tour_autostart && "games"}
      >
      </div>
      <%!-- Tagline: the point of the app is speed at the table — one place to
            ask instead of hunting through rulebooks — plus an up-front caveat
            that answers are AI-generated. --%>
      <%!-- padding-top (not margin) because .main-content:has(.game-list)
            zeroes its own top padding for the sticky controls, leaving this
            block flush against the header otherwise. --%>
      <div style="padding-top:1.25rem;margin-bottom:1rem">
        <p style="font-size:0.92rem;font-weight:600;color:var(--text);margin:0">
          ⚡ Ask a rules question, get a sourced answer in seconds — keep the game moving instead of flipping through rulebooks.
        </p>
        <p style="font-size:0.75rem;color:var(--text-muted);margin:0.25rem 0 0">
          🤖 AI-powered with strict guardrails: every answer is grounded in the actual rulebook text and cites its sources. AI can still be wrong — double-check anything important.
        </p>
        <%!-- Rule of the day: one obscure generated fact, rotating with the
              UTC date. Links to the game it came from. --%>
        <.link
          :if={@rule_of_day}
          navigate={~p"/games/#{@rule_of_day.game}"}
          style="display:block;margin-top:0.75rem;padding:0.6rem 0.75rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg-subtle);text-decoration:none;color:var(--text)"
          title={"Open #{@rule_of_day.game.name}"}
        >
          <span style="font-size:0.62rem;font-weight:700;letter-spacing:0.04em;text-transform:uppercase;color:var(--accent-ink, var(--accent))">
            📅 Rule of the day · {@rule_of_day.game.name}
          </span>
          <span style="display:block;font-size:0.78rem;line-height:1.5;margin-top:0.2rem">
            {@rule_of_day.fact}
          </span>
        </.link>
      </div>
      <div class="list-controls">
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
          <%!-- Mobile: actions that get their own button row on desktop fold
                into this disclosure menu so the game list starts higher. --%>
          <details class="card-menu show-mobile" style="flex-shrink:0">
            <summary
              title="More actions"
              aria-label="More actions"
              style="cursor:pointer;list-style:none;user-select:none;display:inline-flex;align-items:center;gap:0.25rem;padding:0.25rem 0.6rem;border-radius:9999px;font-size:0.78rem;font-weight:600;border:1.5px solid var(--border);background:var(--bg-subtle);color:var(--text-secondary)"
            >
              ⚙️ <span aria-hidden="true" style="font-size:0.6rem;opacity:0.6">▾</span>
            </summary>
            <div class="card-menu__pop card-menu__pop--wide">
              <.link
                :if={RuleMaven.Users.can?(@current_user, :admin)}
                navigate={~p"/games/new"}
                class="card-menu__item"
              >➕ Add Game</.link>
              <.link navigate={~p"/games/import"} class="card-menu__item">
                🔄 Sync Your BGG Collection
              </.link>
            </div>
          </details>
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
          <div class="mb-4 flex gap-2 flex-wrap category-pills">
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
              >{RuleMaven.Games.Category.label(cat)}</button>
            <% end %>
          </div>
        <% end %>

        <%!-- Desktop only: on mobile both actions live in the ⚙️ disclosure
              menu at the head of the view pills (data-tour stays here; the
              tour step is skipped on mobile where this row is hidden). --%>
        <div class="flex gap-2 flex-wrap hide-mobile">
          <.button
            :if={RuleMaven.Users.can?(@current_user, :admin)}
            variant="primary"
            navigate={~p"/games/new"}
          >+ Add Game</.button>
          <.button variant="secondary" navigate={~p"/games/import"} data-tour="bgg-sync">
            Sync Your BGG Collection
          </.button>
        </div>
      </div>

      <% filtered = filtered_games(@games, @search, @category_filter) %>
      <% display_games = visible_games(assigns) %>

      <%= if @search != nil do %>
        <div class="space-y-3" id="game-list" phx-hook="GameListScroll">
          <%= for {game, idx} <- Enum.with_index(display_games) do %>
            <% expansion_count = Map.get(@expansion_counts, game.id, 0) %>
            <% expanded = Map.get(@expanded_games, game.id) %>
            <% has_source = Map.get(@source_counts, game.id, 0) > 0 %>
            <%!-- In "My Collection", games without a rulebook are shown grayed
                  out with nothing to do but request support. --%>
            <% unsupported = @view == "mine" and not has_source %>
            <%!-- Admins can pull BGG data for any showing game that lacks it. --%>
            <% needs_pull =
              RuleMaven.Users.can?(@current_user, :admin) and not is_nil(game.bgg_id) and
                is_nil(game.bgg_data) %>
            <div
              id={"game-card-#{idx}"}
              class="border rounded-lg p-4 flex items-center gap-4 game-card"
              phx-click={unless unsupported, do: "go_to_game"}
              phx-value-id={game.id}
              style={"#{if unsupported, do: "cursor:default;opacity:0.55;filter:grayscale(1)", else: "cursor:pointer"};#{if @selected_idx == idx, do: ";outline:2px solid var(--accent);outline-offset:-2px;background:var(--bg-subtle)", else: ""}"}
            >
              <%= if game.image_url do %>
                <img
                  src={game.image_url}
                  alt={game.name}
                  style="width:60px;height:60px;object-fit:cover;border-radius:0.375rem;flex-shrink:0;pointer-events:none"
                />
              <% end %>
              <div class="flex-1 min-w-0" style="pointer-events:none">
                <h2 class="text-lg font-semibold">
                  {game.name}
                  <span
                    :if={game.playable}
                    title="Ready to play — rulebook reviewed and searchable"
                    style="font-size:0.6rem;font-weight:700;vertical-align:middle;color:var(--green,#16a34a);border:1px solid var(--green,#16a34a);border-radius:999px;padding:0.05rem 0.4rem;margin-left:0.4rem"
                  >
                    ✓ Ready
                  </span>
                </h2>
                <p class="text-sm text-gray-500">
                  <span style="font-size:0.7rem;font-weight:600;opacity:0.65">{RuleMaven.Games.Category.label(
                    game.category
                  )}</span>
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
                  <.difficulty_badge weight={game.weight} />
                </p>
                <%!-- The expansions line doubles as the expand/collapse toggle;
                      pointer-events re-enabled so it's clickable inside the
                      otherwise click-through (go_to_game) metadata column. --%>
                <div
                  :if={expansion_count > 0}
                  style="margin-top:0.2rem;display:flex;gap:0.5rem;align-items:center;pointer-events:auto"
                >
                  <button
                    type="button"
                    phx-click="toggle_expansions"
                    phx-value-id={game.id}
                    style="background:none;border:none;padding:0;color:var(--accent-ink, var(--accent));font-weight:600;font-size:0.8rem;cursor:pointer;line-height:1.2"
                  >{if expanded, do: "▲", else: "▼"} {expansion_count} expansion(s)</button>
                  <% exp_to_pull = Map.get(@expansion_pull_counts, game.id, 0) %>
                  <% exp_syncing = Map.has_key?(@expansion_sync, game.id) %>
                  <button
                    :if={
                      RuleMaven.Users.can?(@current_user, :admin) and (exp_to_pull > 0 or exp_syncing)
                    }
                    type="button"
                    phx-click="pull_expansions"
                    phx-value-id={game.id}
                    disabled={exp_syncing}
                    title="Pull BGG data for expansions missing it"
                    class="btn-outline btn-xs"
                    style={"cursor:#{if exp_syncing, do: "default", else: "pointer"};opacity:#{if exp_syncing, do: "0.6", else: "1"}"}
                  >{if exp_syncing, do: "⟳ Syncing…", else: "⬇ Exp (#{exp_to_pull})"}</button>
                </div>
              </div>
              <% is_admin = RuleMaven.Users.can?(@current_user, :admin) %>
              <% in_collection = MapSet.member?(@collection_ids, game.id) %>
              <% favorited = MapSet.member?(@favorite_ids, game.id) %>
              <div class="flex gap-1.5 flex-shrink-0 game-actions items-center">
                <%!-- Progressive disclosure: only the primary action (Ask /
                      Request / admin Pull) and the favorite heart sit on the
                      card. Everything else lives in the "⋯" menu. --%>
                <button
                  :if={needs_pull}
                  type="button"
                  phx-click="pull_bgg"
                  phx-value-id={game.id}
                  disabled={MapSet.member?(@bgg_pulling, game.id)}
                  class="btn-primary btn-xs"
                  style={"cursor:#{if MapSet.member?(@bgg_pulling, game.id), do: "default", else: "pointer"};opacity:#{if MapSet.member?(@bgg_pulling, game.id), do: "0.6", else: "1"}"}
                >{if MapSet.member?(@bgg_pulling, game.id), do: "⟳ Pulling…", else: "⬇ Pull BGG"}</button>
                <%= if unsupported do %>
                  <% requested = MapSet.member?(@requested_ids, game.id) %>
                  <%= if requested do %>
                    <span style="color:var(--text-muted);font-size:0.75rem;font-weight:600;padding:0.2rem 0.55rem;line-height:1.2">Requested ✓</span>
                  <% else %>
                    <button
                      type="button"
                      phx-click="request_support"
                      phx-value-id={game.id}
                      class="btn-outline btn-xs"
                    >Request</button>
                  <% end %>
                <% else %>
                  <% askable =
                    Map.get(@source_counts, game.id, 0) > 0 and
                      (game.playable or is_admin) %>
                  <.link
                    :if={askable}
                    navigate={~p"/games/#{game}"}
                    class="btn btn-primary btn-xs"
                  >Ask</.link>
                  <.link
                    :if={askable}
                    navigate={~p"/games/#{game}/community"}
                    title="Browse community Q&A — questions other players already asked"
                    class="btn btn-xs"
                  >Q&A</.link>
                  <button
                    type="button"
                    phx-click="toggle_favorite"
                    phx-value-id={game.id}
                    title={if favorited, do: "Remove from favorites", else: "Add to favorites"}
                    class="btn-icon btn-xs"
                    style={"background:#{if favorited, do: "color-mix(in srgb,var(--red) 14%,transparent)", else: "var(--bg-subtle)"};color:#{if favorited, do: "var(--red)", else: "var(--text-muted)"}"}
                  >{if favorited, do: "♥", else: "♡"}</button>
                <% end %>
                <.card_menu>
                  <button
                    type="button"
                    phx-click="toggle_collection"
                    phx-value-id={game.id}
                    class="card-menu__item"
                    title={unless in_collection, do: "Games you own"}
                  >{if in_collection, do: "✓ In collection — remove", else: "+ Add to collection"}</button>
                  <a
                    :if={game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(game.category)}
                    id={"bgg-link-#{game.id}"}
                    href={"https://boardgamegeek.com/boardgame/#{game.bgg_id}"}
                    target="_blank"
                    rel="noopener"
                    phx-hook="ExternalLink"
                    class="card-menu__item"
                  >View on BGG ↗</a>
                  <%= if is_admin do %>
                    <div class="card-menu__divider"></div>
                    <.link
                      :if={has_source and RuleMaven.Games.bgg_synced?(game)}
                      href={~p"/games/#{game}/prepare"}
                      class="card-menu__item"
                    >{if game.playable, do: "Readiness →", else: "Prepare →"}</.link>
                    <.link navigate={~p"/games/#{game}/edit"} class="card-menu__item">Edit</.link>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={game.id}
                      data-confirm={"Delete #{game.name}? This cannot be undone."}
                      class="card-menu__item card-menu__item--err"
                    >Delete…</button>
                  <% end %>
                </.card_menu>
              </div>
            </div>

            <%= if expanded && expansion_count > 0 do %>
              <% expansions =
                if RuleMaven.Users.can?(@current_user, :admin),
                  do: Games.expansions_for(game),
                  else: Games.expansions_with_documents(game) %>
              <% sync = Map.get(@expansion_sync, game.id) %>
              <div class="exp-reveal">
                <div
                  :if={sync}
                  style="margin-left:2rem;margin-bottom:0.4rem;display:flex;align-items:center;gap:0.5rem;font-size:0.75rem;color:var(--accent-ink, var(--accent));font-weight:600"
                >
                  <% {done, total} = sync %>
                  <span class="animate-pulse">⟳ Syncing expansions {done}/{total}…</span>
                </div>
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
                      <h2 class="text-base font-semibold">
                        {exp.name}
                        <span
                          :if={sync && exp.bgg_data}
                          style="color:var(--green);font-size:0.7rem;font-weight:600"
                        >✓</span>
                        <span
                          :if={sync && is_nil(exp.bgg_data)}
                          class="animate-pulse"
                          style="color:var(--text-muted);font-size:0.7rem;font-weight:600"
                        >⏳</span>
                      </h2>
                      <p class="text-xs text-gray-500">
                        Expansion
                        <%= if exp.year_published do %>
                          &middot; {exp.year_published}
                        <% end %>
                      </p>
                    </div>
                    <% exp_admin = RuleMaven.Users.can?(@current_user, :admin) %>
                    <% exp_bgg = exp.bgg_id && RuleMaven.Games.Category.bgg_relevant?(exp.category) %>
                    <div class="flex gap-1.5 flex-shrink-0 game-actions items-center">
                      <.link
                        :if={Map.get(@source_counts, exp.id, 0) > 0}
                        navigate={~p"/games/#{exp}"}
                        class="btn btn-primary btn-xs"
                      >Ask</.link>
                      <.card_menu :if={exp_bgg || exp_admin}>
                        <a
                          :if={exp_bgg}
                          id={"bgg-link-exp-#{exp.id}"}
                          href={"https://boardgamegeek.com/boardgame/#{exp.bgg_id}"}
                          target="_blank"
                          rel="noopener"
                          phx-hook="ExternalLink"
                          class="card-menu__item"
                        >View on BGG ↗</a>
                        <%= if exp_admin do %>
                          <div :if={exp_bgg} class="card-menu__divider"></div>
                          <.link navigate={~p"/games/#{exp}/edit"} class="card-menu__item">Edit</.link>
                          <button
                            type="button"
                            phx-click="confirm_delete"
                            phx-value-id={exp.id}
                            data-confirm={"Delete #{exp.name}? This cannot be undone."}
                            class="card-menu__item card-menu__item--err"
                          >Delete…</button>
                        <% end %>
                      </.card_menu>
                    </div>
                  </div>
                <% end %>
              </div>
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
              class="btn btn-primary btn-sm"
            >🔍 Sync Your BGG Collection</.link>
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
