defmodule RuleMavenWeb.GameLive.ToolHost do
  @moduledoc """
  Shared table-tool machinery for every user-facing game LiveView (Show,
  Community): the cached-data loaders, the window-state event handlers, and
  TableSession hydration/write-through so open windows follow the user across
  pages. LiveView resolves events per-view, so each host view adds one
  delegating `handle_event` clause guarded by `event in ToolHost.events()`.

  Requires `:current_user`, `:coarse_pointer` (and `:game` once mounted)
  assigns on the socket. `mount_tools/2` must run once per LiveView mount —
  not per handle_params — or open windows would reset on every patch.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias RuleMaven.TableSession
  alias RuleMavenWeb.GameLive.ToolRegistry

  # Volatile per-tool state worth carrying across page navigations. Checklist
  # ticks and score-pad entries already persist in browser localStorage.
  @session_keys [
    :tool_states,
    :tool_order,
    :quiz_idx,
    :quiz_choice,
    :quiz_score,
    :turn_phase,
    :turn_open,
    :fp_pick
  ]

  @events ~w(open_tool expand_tool minimize_tool close_tool focus_tool
             shuffle_rule roll_first_player quiz_answer quiz_next quiz_restart
             turn_toggle turn_next turn_prev turn_restart
             toggle_step reset_checklist checklist_restore
             toggle_house_rules_card toggle_house_rule_form add_house_rule
             start_edit_house_rule cancel_edit_house_rule edit_house_rule
             delete_house_rule toggle_house_rule_visibility toggle_house_rule_enabled
             recheck_house_rule block_house_rule toggle_expansion)

  def events, do: @events
  def session_keys, do: @session_keys

  # ── Mount ────────────────────────────────────────────────────────────────

  @doc """
  Everything `mount_tools/2` and `SubBar.game_header/1` need that a page might
  not already carry: the pointer split (connect params are mount-only), the
  admin flag, the source list and the community-question count. Existing
  assigns win, so a page that loaded documents itself pays no second query.

  Call once, at mount, before `mount_tools/2`.
  """
  def mount_header(socket, game) do
    socket
    |> put_new(:coarse_pointer, fn s ->
      connected?(s) and get_connect_params(s)["coarse_pointer"] == true
    end)
    |> put_new(:is_admin, fn s -> RuleMaven.Users.can?(s.assigns.current_user, :admin) end)
    |> put_new(:sources, fn _s -> RuleMaven.Games.list_documents(game) end)
    |> put_new(:community_count, fn _s -> RuleMaven.Faq.community_count(game) end)
    |> put_new(:has_cheatsheet, fn s -> has_cheatsheet?(s.assigns.sources) end)
    # Same source Show uses (`expansions_with_documents/1`, not the more
    # permissive `expansions_for/1`): an expansion with no published rulebook
    # has nothing to answer questions from, so it isn't a real toggle choice.
    # Keeping the same query here means `effective_expansion_ids/2` (below)
    # is filtering against the identical "available" set this page renders.
    |> put_new(:expansions, fn _s -> RuleMaven.Games.expansions_with_documents(game) end)
    |> put_new(:included_expansions, fn s ->
      s.assigns.current_user.id
      |> RuleMaven.Games.effective_expansion_ids(game)
      |> Map.new(&{&1, true})
    end)
  end

  @doc """
  Whether any of the game's sources has an active cheat-sheet version.

  One query per source, so it is computed once at mount and passed down as an
  assign — the sub-bar renders on every game page and would otherwise re-run it
  on each render, once for the More menu and once for the pill.
  """
  def has_cheatsheet?(sources) do
    Enum.any?(sources, &(RuleMaven.CheatSheet.active_version(&1.id) != nil))
  end

  defp put_new(socket, key, fun) do
    if Map.has_key?(socket.assigns, key), do: socket, else: assign(socket, key, fun.(socket))
  end

  @doc """
  Assigns every tool's data + window state, then re-opens whatever the
  TableSession snapshot says was open for this user+game.
  """
  def mount_tools(socket, game) do
    user = socket.assigns.current_user
    sources = socket.assigns[:sources] || RuleMaven.Games.list_documents(game)
    dyk_facts = load_did_you_know(game, sources, connected?(socket))
    {setup_status, setup_checklist} = load_setup(game, sources)
    seed = socket.assigns[:dyk_seed] || :erlang.unique_integer()
    own_house_rules = load_own_house_rules(game, user)

    socket
    |> assign(
      sources: sources,
      dyk_facts: dyk_facts,
      rule_card: dyk_card_for(dyk_facts, seed),
      setup_status: setup_status,
      setup_checklist: setup_checklist,
      fp_selectors: load_first_player(game),
      fp_pick: nil,
      common_mistakes: load_common_mistakes(game),
      teach_pitch: load_teach_pitch(game),
      score_categories: load_score_categories(game),
      turn_flow: load_turn_flow(game),
      turn_phase: 0,
      turn_open: false,
      quiz: load_quiz(game),
      quiz_idx: 0,
      quiz_choice: nil,
      quiz_score: {0, 0},
      tool_states: %{},
      tool_order: [],
      single_panel?: socket.assigns.coarse_pointer,
      house_rules: own_house_rules,
      house_rule_count: length(own_house_rules),
      community_house_rules: RuleMaven.HouseRules.community_for_game(game.id, user && user.id),
      hr_card_open: Map.get(socket.assigns, :hr_card_open, true),
      hr_form_open: false,
      hr_editing_id: nil
    )
    |> ensure_checklist_defaults()
    |> hydrate(game, user)
  end

  # Community has no expansion machinery; the checklist tool renders
  # @expansion_deltas + @checklist_done, so give them safe defaults there.
  defp ensure_checklist_defaults(socket) do
    socket
    |> then(fn s ->
      if Map.has_key?(s.assigns, :expansion_deltas), do: s, else: assign(s, :expansion_deltas, [])
    end)
    |> then(fn s ->
      if Map.has_key?(s.assigns, :checklist_done),
        do: s,
        else: assign(s, :checklist_done, MapSet.new())
    end)
  end

  defp hydrate(socket, _game, nil), do: socket

  defp hydrate(socket, game, user) do
    snap = TableSession.get(user.id, game.id)

    states =
      for {id, st} <- Map.get(snap, :tool_states, %{}),
          ToolRegistry.valid?(id),
          st in [:expanded, :minimized],
          into: %{},
          do: {id, st}

    # Phones stack one sheet at a time: demote all but the top expanded window.
    states =
      if socket.assigns.single_panel? do
        top = snap |> Map.get(:tool_order, []) |> List.last()

        for {id, st} <- states, into: %{} do
          if st == :expanded and id != top, do: {id, :minimized}, else: {id, st}
        end
      else
        states
      end

    order = snap |> Map.get(:tool_order, []) |> Enum.filter(&(states[&1] == :expanded))
    turn_last = max(length(socket.assigns.turn_flow) - 1, 0)

    assign(socket,
      tool_states: states,
      tool_order: order,
      quiz_idx: min(Map.get(snap, :quiz_idx, 0), length(socket.assigns.quiz)),
      quiz_choice: Map.get(snap, :quiz_choice, nil),
      quiz_score: Map.get(snap, :quiz_score, {0, 0}),
      turn_phase: snap |> Map.get(:turn_phase, 0) |> min(turn_last),
      turn_open: Map.get(snap, :turn_open, false),
      fp_pick: Map.get(snap, :fp_pick, nil)
    )
  end

  defp persist(socket) do
    with %{id: uid} <- socket.assigns.current_user,
         %{id: gid} <- socket.assigns.game do
      TableSession.put(uid, gid, Map.take(socket.assigns, @session_keys))
    end

    socket
  end

  defp assign_persist(socket, kv), do: socket |> assign(kv) |> persist()

  # ── Window state ─────────────────────────────────────────────────────────

  def handle_tool_event("open_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :expanded)}
  end

  def handle_tool_event("expand_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :expanded)}
  end

  def handle_tool_event("minimize_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :minimized)}
  end

  def handle_tool_event("close_tool", %{"tool" => tool}, socket) do
    id = safe_tool_id(tool)

    states =
      if id, do: Map.delete(socket.assigns.tool_states, id), else: socket.assigns.tool_states

    order = Enum.filter(socket.assigns.tool_order, &(states[&1] == :expanded))
    {:noreply, assign_persist(socket, tool_states: states, tool_order: order)}
  end

  # Click-to-front. The client raises z-index immediately (no round-trip), but
  # the server keeps the order so a re-render doesn't resurrect the old stack.
  def handle_tool_event("focus_tool", %{"tool" => tool}, socket) do
    case safe_tool_id(tool) do
      nil ->
        {:noreply, socket}

      id ->
        if socket.assigns.tool_states[id] == :expanded do
          {:noreply,
           assign_persist(socket,
             tool_order: bump_order(socket.assigns.tool_order, id, :expanded)
           )}
        else
          {:noreply, socket}
        end
    end
  end

  # ── Did-you-know / first player ──────────────────────────────────────────

  def handle_tool_event("shuffle_rule", _params, socket) do
    {:noreply, assign(socket, rule_card: fact_card(socket.assigns.dyk_facts))}
  end

  # Re-roll until it lands on something new, so mashing the button never
  # repeats (with 2+ selectors).
  def handle_tool_event("roll_first_player", _params, socket) do
    pick =
      socket.assigns.fp_selectors
      |> Enum.reject(&(&1 == socket.assigns.fp_pick))
      |> case do
        [] -> socket.assigns.fp_pick
        rest -> Enum.random(rest)
      end

    {:noreply, assign_persist(socket, fp_pick: pick)}
  end

  # ── Quiz ─────────────────────────────────────────────────────────────────

  # First tap on a choice locks it in and scores it; later taps are ignored.
  def handle_tool_event("quiz_answer", %{"choice" => choice_str}, socket) do
    with nil <- socket.assigns.quiz_choice,
         {choice, ""} <- Integer.parse(choice_str),
         %{"answer" => answer, "choices" => choices} <-
           Enum.at(socket.assigns.quiz, socket.assigns.quiz_idx),
         true <- choice >= 0 and choice < length(choices) do
      {right, asked} = socket.assigns.quiz_score
      right = if choice == answer, do: right + 1, else: right

      {:noreply, assign_persist(socket, quiz_choice: choice, quiz_score: {right, asked + 1})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_tool_event("quiz_next", _params, socket) do
    {:noreply, assign_persist(socket, quiz_idx: socket.assigns.quiz_idx + 1, quiz_choice: nil)}
  end

  def handle_tool_event("quiz_restart", _params, socket) do
    {:noreply,
     assign_persist(socket,
       quiz: Enum.shuffle(socket.assigns.quiz),
       quiz_idx: 0,
       quiz_choice: nil,
       quiz_score: {0, 0}
     )}
  end

  # ── Turn wizard ──────────────────────────────────────────────────────────
  # Step through the cached turn phases (pure navigation over already-loaded
  # data — no LLM at play time). Clamp to bounds. `turn_open` is
  # server-controlled so the LiveView re-render on nav doesn't strip the
  # browser-set `open` attr off the <details> (which collapsed it).

  def handle_tool_event("turn_toggle", _params, socket) do
    {:noreply, assign_persist(socket, turn_open: !socket.assigns.turn_open)}
  end

  def handle_tool_event("turn_next", _params, socket) do
    last = max(length(socket.assigns.turn_flow) - 1, 0)

    {:noreply,
     assign_persist(socket,
       turn_phase: min(socket.assigns.turn_phase + 1, last),
       turn_open: true
     )}
  end

  def handle_tool_event("turn_prev", _params, socket) do
    {:noreply,
     assign_persist(socket,
       turn_phase: max(socket.assigns.turn_phase - 1, 0),
       turn_open: true
     )}
  end

  def handle_tool_event("turn_restart", _params, socket) do
    {:noreply, assign_persist(socket, turn_phase: 0, turn_open: true)}
  end

  # ── Setup checklist ──────────────────────────────────────────────────────

  def handle_tool_event("toggle_step", %{"key" => key}, socket) do
    done = socket.assigns.checklist_done

    done =
      if MapSet.member?(done, key),
        do: MapSet.delete(done, key),
        else: MapSet.put(done, key)

    {:noreply, socket |> assign(checklist_done: done) |> push_checklist_save(done)}
  end

  def handle_tool_event("reset_checklist", _params, socket) do
    done = MapSet.new()
    {:noreply, socket |> assign(checklist_done: done) |> push_checklist_save(done)}
  end

  # Restore checked items from the browser's localStorage (pushed by the
  # ChecklistStore hook on connect). Persists per-browser, not per-account.
  def handle_tool_event("checklist_restore", %{"keys" => keys}, socket) when is_list(keys) do
    {:noreply, assign(socket, checklist_done: MapSet.new(keys))}
  end

  def handle_tool_event("checklist_restore", _params, socket), do: {:noreply, socket}

  # ── Expansions ───────────────────────────────────────────────────────────

  def handle_tool_event("toggle_expansion", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    included = socket.assigns.included_expansions

    included =
      if included[id], do: Map.delete(included, id), else: Map.put(included, id, true)

    RuleMaven.Games.put_expansion_selection(
      socket.assigns.current_user.id,
      socket.assigns.game.id,
      Map.keys(included)
    )

    {:noreply,
     socket
     |> assign(included_expansions: included)
     |> refresh_expansion_deltas()}
  end

  # Only the Q&A screen carries `expansion_deltas` (it drives the "How does my
  # rule change this answer?" overlay there). Community has no such assign,
  # and recomputing it unconditionally would raise on that page.
  defp refresh_expansion_deltas(socket) do
    if Map.has_key?(socket.assigns, :expansion_deltas) do
      assign(socket,
        expansion_deltas:
          load_expansion_deltas(socket.assigns.expansions, socket.assigns.included_expansions)
      )
    else
      socket
    end
  end

  # Deltas for the currently-included expansions that have one stored, in
  # expansion-name order (the `expansions` assign is already name-sorted).
  def load_expansion_deltas(expansions, included) do
    expansions
    |> Enum.filter(&Map.get(included, &1.id))
    |> Enum.flat_map(fn exp ->
      case RuleMaven.ExpansionDelta.stored(exp.id) do
        nil -> []
        delta -> [{exp, delta}]
      end
    end)
  end

  # ── House rules ──────────────────────────────────────────────────────────

  def handle_tool_event("toggle_house_rules_card", _params, socket) do
    {:noreply, assign(socket, hr_card_open: !socket.assigns.hr_card_open)}
  end

  def handle_tool_event("toggle_house_rule_form", _params, socket) do
    {:noreply, assign(socket, hr_form_open: !socket.assigns.hr_form_open)}
  end

  def handle_tool_event("add_house_rule", %{"house_rule" => params}, socket) do
    %{game: game, current_user: user} = socket.assigns

    case RuleMaven.HouseRules.submit(user, game.id, params) do
      {:ok, _hr} ->
        own_house_rules = load_own_house_rules(game, user)

        {:noreply,
         socket
         |> assign(
           house_rules: own_house_rules,
           house_rule_count: length(own_house_rules),
           hr_form_open: false
         )
         |> put_flash(:info, "House rule added — checking it against the rulebook…")}

      {:error, :injection} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a house rule.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, changeset_error_text(cs))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_tool_event("start_edit_house_rule", %{"id" => id}, socket) do
    id = to_integer(id)
    hr = get_house_rule(id)

    if hr && owner?(socket, hr) do
      {:noreply, assign(socket, hr_editing_id: id)}
    else
      {:noreply, socket}
    end
  end

  def handle_tool_event("cancel_edit_house_rule", _params, socket) do
    {:noreply, assign(socket, hr_editing_id: nil)}
  end

  def handle_tool_event("edit_house_rule", %{"id" => id, "house_rule" => params}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr),
         {:ok, _} <-
           RuleMaven.HouseRules.update_and_recheck(socket.assigns.current_user, hr, params) do
      {:noreply, socket |> assign(hr_editing_id: nil) |> refresh_house_rules()}
    else
      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, :injection} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a house rule.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that house rule.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_tool_event("delete_house_rule", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr) do
      {:ok, _} = RuleMaven.HouseRules.delete(hr)
    end

    {:noreply, refresh_house_rules(socket)}
  end

  def handle_tool_event("toggle_house_rule_visibility", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr) do
      new_vis = if hr.visibility == "community", do: "private", else: "community"
      {:ok, _} = RuleMaven.HouseRules.update(hr, %{"visibility" => new_vis})
    end

    {:noreply, refresh_house_rules(socket)}
  end

  # `set_enabled/3` does its own ownership check and returns {:error, :unauthorized},
  # so a forged phx-value-id for someone else's rule is a no-op.
  def handle_tool_event("toggle_house_rule_enabled", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id) do
      RuleMaven.HouseRules.set_enabled(socket.assigns.current_user, hr, !hr.enabled)
    end

    {:noreply, refresh_house_rules(socket)}
  end

  def handle_tool_event("recheck_house_rule", %{"id" => id}, socket) do
    with %{} = hr <- get_house_rule(id),
         true <- owner?(socket, hr),
         {:ok, _} <- RuleMaven.HouseRules.resubmit_check(socket.assigns.current_user, hr) do
      {:noreply, refresh_house_rules(socket)}
    else
      {:error, msg} when is_binary(msg) -> {:noreply, put_flash(socket, :error, msg)}
      _ -> {:noreply, socket}
    end
  end

  def handle_tool_event("block_house_rule", %{"id" => id}, socket) do
    if RuleMaven.Users.can?(socket.assigns.current_user, :admin) do
      # Scoped: `id` is off the wire, so confine the block to this game's rules.
      with %{} = hr <- get_house_rule(id),
           true <- hr.game_id == socket.assigns.game.id do
        {:ok, _} = RuleMaven.HouseRules.set_blocked(hr, !hr.blocked)
      end
    end

    {:noreply, refresh_house_rules(socket)}
  end

  # ── Shared helpers (also used by Show) ───────────────────────────────────

  # Guards HouseRules.get/1 against a nil id (a non-numeric phx-value-id):
  # Repo.get/2 raises ArgumentError on a nil primary key, so a crafted
  # non-numeric id must short-circuit to nil rather than reach the repo.
  def get_house_rule(nil), do: nil
  def get_house_rule(id), do: id |> to_integer() |> get_house_rule_by_int()

  defp get_house_rule_by_int(nil), do: nil
  defp get_house_rule_by_int(int), do: RuleMaven.HouseRules.get(int)

  def owner?(socket, hr) do
    u = socket.assigns.current_user
    u && u.id == hr.user_id
  end

  # Reload both house-rule lists. The answer overlay is Show-only; Show pipes
  # its own load_hr_overlay after delegated house-rule events.
  def refresh_house_rules(socket) do
    %{game: game, current_user: user} = socket.assigns
    own_house_rules = load_own_house_rules(game, user)

    assign(socket,
      house_rules: own_house_rules,
      house_rule_count: length(own_house_rules),
      community_house_rules: RuleMaven.HouseRules.community_for_game(game.id, user && user.id)
    )
  end

  def load_own_house_rules(_game, nil), do: []
  def load_own_house_rules(game, user), do: RuleMaven.HouseRules.list_for_user(game.id, user.id)

  # ── Cached-data loaders ──────────────────────────────────────────────────
  # All read the durable per-game Settings blobs generated at finalize; empty
  # until the corresponding worker has run (the tool renders "not available").

  # Subscribe so a finalize while this page is open streams facts in live;
  # never enqueue here.
  def load_did_you_know(game, sources, connected?) do
    case RuleMaven.Settings.get("did_you_know_#{game.id}") do
      nil ->
        if sources != [] and connected? do
          Phoenix.PubSub.subscribe(
            RuleMaven.PubSub,
            RuleMaven.Workers.DidYouKnowWorker.topic(game.id)
          )
        end

        []

      json ->
        Jason.decode!(json)
    end
  end

  # Returns {status, checklist}. (The host view subscribes to Setup.topic.)
  def load_setup(game, _sources) do
    {RuleMaven.Setup.status(game.id), RuleMaven.Setup.stored_checklist(game.id)}
  end

  def load_first_player(game) do
    case RuleMaven.Settings.get("first_player_#{game.id}") do
      nil -> []
      json -> Jason.decode!(json)
    end
  end

  def load_common_mistakes(game) do
    case RuleMaven.Settings.get("common_mistakes_#{game.id}") do
      nil -> []
      json -> Jason.decode!(json)
    end
  end

  def load_teach_pitch(game) do
    case RuleMaven.Settings.get("teach_pitch_#{game.id}") do
      nil -> %{}
      json -> Jason.decode!(json)
    end
  end

  def load_score_categories(game) do
    case RuleMaven.Settings.get("score_categories_#{game.id}") do
      nil -> []
      json -> Jason.decode!(json)
    end
  end

  def load_turn_flow(game) do
    case RuleMaven.Settings.get("turn_flow_#{game.id}") do
      nil -> []
      json -> Jason.decode!(json)
    end
  end

  # Loaded in stored order so the static and connected mounts agree; "Play
  # again" shuffles.
  def load_quiz(game) do
    case RuleMaven.Settings.get("quiz_#{game.id}") do
      nil -> []
      json -> Jason.decode!(json)
    end
  end

  # Wrap a random generated fact in the shape the card template expects, or nil
  # when none have been generated yet (the card is simply hidden). Generated
  # facts have no page citation.
  def fact_card([]), do: nil
  def fact_card(facts), do: %{content: Enum.random(facts), page_number: nil}

  # Deterministic fact pick for the initial render: the static and connected
  # mounts must agree, else the card flickers or shifts layout on connect.
  def dyk_card_for([], _seed), do: nil

  def dyk_card_for(facts, seed) do
    idx = rem(:erlang.phash2(seed), length(facts))
    %{content: Enum.at(facts, idx), page_number: nil}
  end

  # ── Private plumbing ─────────────────────────────────────────────────────

  # Only accept ids the registry knows; ignore anything else (events are
  # client-driven). Returns the atom id or nil.
  defp safe_tool_id(tool) when is_binary(tool) do
    id = String.to_existing_atom(tool)
    if ToolRegistry.valid?(id), do: id, else: nil
  rescue
    ArgumentError -> nil
  end

  defp safe_tool_id(_), do: nil

  defp update_tool_state(socket, tool, state) do
    case safe_tool_id(tool) do
      nil ->
        socket

      id ->
        single? = socket.assigns.single_panel?
        states = set_tool_state(socket.assigns.tool_states, id, state, single?)

        # A demoted window leaves the stack too, not just the id we touched.
        order =
          socket.assigns.tool_order
          |> bump_order(id, state)
          |> Enum.filter(&(states[&1] == :expanded))

        assign_persist(socket, tool_states: states, tool_order: order)
    end
  end

  # Desktop stacks tool windows: several may be :expanded at once. A phone has
  # no room to stack bottom sheets, so there it stays one-at-a-time and opening
  # a tool demotes whoever was expanded.
  defp set_tool_state(states, id, state, single?) do
    states
    |> Enum.map(fn
      {k, :expanded} when k != id and single? -> {k, :minimized}
      other -> other
    end)
    |> Map.new()
    |> Map.put(id, state)
  end

  # Front-to-back order of the expanded windows, back first: a freshly opened
  # or focused tool goes to the end (on top). Minimized/closed tools drop out.
  # The list is the render order; the client raises z-index on click from there.
  defp bump_order(order, id, :expanded), do: (order -- [id]) ++ [id]
  defp bump_order(order, id, _state), do: order -- [id]

  # Push the current checked-item set to the browser so the ChecklistStore hook
  # can persist it in localStorage (keyed per game).
  defp push_checklist_save(socket, done) do
    push_event(socket, "save_checklist", %{
      game_id: socket.assigns.game.id,
      keys: MapSet.to_list(done)
    })
  end

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp changeset_error_text(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end
end
