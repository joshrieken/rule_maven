# Sub-bar Everywhere + Persistent Tool Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Game sub-bar (Play/Learn/More) + working tool windows on the Community page; tool windows survive thread switches and page-to-page navigation via a server-side TableSession store; desktop minimized-tool bar sits in normal flow above the composer.

**Architecture:** Extract tool data-loading + event handling from `GameLive.Show` into a shared `GameLive.ToolHost` module used by both Show and Community. Volatile tool state write-throughs to `RuleMaven.TableSession` (ETS, keyed `{user_id, game_id}`) and is re-hydrated at mount. The minimized dock is split out of `ToolPanel.tool_panel/1` so Show can render it in-flow inside the chat column.

**Tech Stack:** Phoenix LiveView, ExUnit + Phoenix.LiveViewTest, ETS. Assets are plain files under `priv/static/assets` (no build step).

## Global Constraints

- Mobile-first: every UI change must look right at 390px (hard rule).
- Connect params are mount-only — never read them in handle_params.
- Cross-LiveView `patch` crashes — `navigate` off the owning LiveView.
- Only run test files relevant to the change; tee output to ./tmp.
- Commit after each task.

---

### Task 1: `RuleMaven.TableSession`

**Files:**
- Create: `lib/rule_maven/table_session.ex`
- Modify: `lib/rule_maven/application.ex:15` (children list)
- Test: `test/rule_maven/table_session_test.exs`

**Interfaces:**
- Produces: `TableSession.get(user_id, game_id) :: map` (empty map on miss), `TableSession.put(user_id, game_id, map) :: :ok`, `TableSession.sweep(ttl_ms)` (test hook).

- [ ] **Step 1: failing test** (`test/rule_maven/table_session_test.exs`)

```elixir
defmodule RuleMaven.TableSessionTest do
  use ExUnit.Case, async: false
  alias RuleMaven.TableSession

  test "get on a missing key returns an empty map" do
    assert TableSession.get(-1, -1) == %{}
  end

  test "put then get round-trips the snapshot" do
    :ok = TableSession.put(1, 2, %{tool_states: %{quiz: :expanded}})
    assert TableSession.get(1, 2) == %{tool_states: %{quiz: :expanded}}
  end

  test "sweep drops entries older than the TTL, keeps fresh ones" do
    :ok = TableSession.put(3, 4, %{a: 1})
    :ets.insert(:rule_maven_table_sessions, {{5, 6}, %{b: 2}, System.monotonic_time(:millisecond) - 100_000})
    TableSession.sweep(50_000)
    assert TableSession.get(3, 4) == %{a: 1}
    assert TableSession.get(5, 6) == %{}
  end
end
```

- [ ] **Step 2:** `mix test test/rule_maven/table_session_test.exs` → FAIL (module undefined)
- [ ] **Step 3: implement**

```elixir
defmodule RuleMaven.TableSession do
  @moduledoc """
  In-memory "at the table" session per {user, game}: which tool windows are
  open plus their volatile state, so navigating between game pages (separate
  LiveViews) doesn't close them. Deliberately ephemeral — ETS, lost on
  restart/deploy; durable per-tool data (checklist, score pad) already lives
  in browser localStorage.
  """
  use GenServer

  @table :rule_maven_table_sessions
  @ttl_ms :timer.hours(12)
  @sweep_ms :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Snapshot for this user+game; empty map when absent (or table not up)."
  def get(user_id, game_id) do
    case :ets.lookup(@table, {user_id, game_id}) do
      [{_key, snapshot, _at}] -> snapshot
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  def put(user_id, game_id, snapshot) when is_map(snapshot) do
    :ets.insert(@table, {{user_id, game_id}, snapshot, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drop entries idle longer than ttl_ms. Called on a timer; public for tests."
  def sweep(ttl_ms \\ @ttl_ms) do
    cutoff = System.monotonic_time(:millisecond) - ttl_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
```

Supervision: in `lib/rule_maven/application.ex` add `RuleMaven.TableSession,` after `RuleMaven.LLM.NormalizeCache,`.

- [ ] **Step 4:** run test → PASS
- [ ] **Step 5:** commit `feat: TableSession ETS store for per-game tool sessions`

---

### Task 2: Extract `GameLive.ToolHost`; Show delegates; state survives thread patches

**Files:**
- Create: `lib/rule_maven_web/live/game_live/tool_host.ex`
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (remove moved code; delegate; stop resetting tool assigns per patch)
- Test: `test/rule_maven_web/live/game_live_tool_persistence_test.exs` (new) + existing `game_live_tool_panel_test.exs`, `game_live_turn_wizard_test.exs`, `game_live_house_rules_test.exs` as regression

**Interfaces:**
- Consumes: `TableSession.get/2`, `put/3` (Task 1).
- Produces:
  - `ToolHost.events() :: [String.t()]`
  - `ToolHost.mount_tools(socket, game) :: socket` — assigns ALL tool data (dyk_facts, rule_card, setup_status, setup_checklist, checklist_done default, fp_selectors, fp_pick, common_mistakes, teach_pitch, score_categories, turn_flow, turn_phase, turn_open, quiz, quiz_idx, quiz_choice, quiz_score, tool_states, tool_order, single_panel?, house_rules, community_house_rules, hr_card_open, hr_form_open, hr_editing_id, expansion deltas fallback) then hydrates from TableSession. Requires `:current_user`, `:coarse_pointer` assigns; leaves `:included_expansions`/`:expansion_deltas` alone if already assigned (Show manages them).
  - `ToolHost.handle_tool_event(event, params, socket) :: {:noreply, socket}`
  - Public loaders (moved verbatim from Show, made `def`): `load_did_you_know/3`, `load_setup/2`, `load_first_player/1`, `load_common_mistakes/1`, `load_teach_pitch/1`, `load_score_categories/1`, `load_turn_flow/1`, `load_quiz/1`, `load_own_house_rules/2`, `load_expansion_deltas/2`, `fact_card/1`, `dyk_card_for/2`, `refresh_house_rules/1` (lists only, no overlay).
  - `@session_keys [:tool_states, :tool_order, :quiz_idx, :quiz_choice, :quiz_score, :turn_phase, :turn_open, :fp_pick]`; every mutating handler ends with `persist(socket)`.

- [ ] **Step 1: failing test** — thread patch keeps windows; TableSession snapshot written

```elixir
# test/rule_maven_web/live/game_live_tool_persistence_test.exs
# setup mirrors test/rule_maven_web/live/game_live_tool_panel_test.exs
# (game fixture + token login). Core assertions:
{:ok, view, _html} = live(conn, ~p"/games/#{game}")
view |> element("button[phx-click=open_tool][phx-value-tool=timer]") |> render_click()
assert has_element?(view, "#tool-panel-timer")
# navigate to the overview via patch — window must survive
view |> render_patch(~p"/games/#{game}?start=1")
assert has_element?(view, "#tool-panel-timer")
# snapshot written server-side
assert %{tool_states: %{timer: :expanded}} = RuleMaven.TableSession.get(user.id, game.id)
```

- [ ] **Step 2:** run → FAIL (patch currently resets `tool_states` to `%{}`)
- [ ] **Step 3: implement extraction**

ToolHost skeleton (event handlers, helpers, loaders moved **verbatim** from show.ex; only `defp`→`def` where listed above):

```elixir
defmodule RuleMavenWeb.GameLive.ToolHost do
  @moduledoc """
  Shared table-tool machinery for every user-facing game LiveView (Show,
  Community): data loaders, window-state events, and TableSession
  hydration/write-through so open windows follow the user across pages.
  LiveView resolves events per-view, so each host view adds one delegating
  handle_event clause guarded by `event in ToolHost.events()`.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView
  alias RuleMaven.TableSession
  alias RuleMavenWeb.GameLive.ToolRegistry

  @session_keys [:tool_states, :tool_order, :quiz_idx, :quiz_choice, :quiz_score,
                 :turn_phase, :turn_open, :fp_pick]

  @events ~w(open_tool expand_tool minimize_tool close_tool focus_tool
             shuffle_rule roll_first_player quiz_answer quiz_next quiz_restart
             turn_toggle turn_next turn_prev turn_restart
             toggle_step reset_checklist checklist_restore
             toggle_house_rules_card toggle_house_rule_form add_house_rule
             start_edit_house_rule cancel_edit_house_rule edit_house_rule
             delete_house_rule toggle_house_rule_visibility recheck_house_rule
             block_house_rule)

  def events, do: @events
  def session_keys, do: @session_keys

  def mount_tools(socket, game) do
    user = socket.assigns.current_user
    sources = socket.assigns[:sources] || RuleMaven.Games.list_documents(game)
    dyk_facts = load_did_you_know(game, sources, connected?(socket))
    {setup_status, setup_checklist} = load_setup(game, sources)
    seed = socket.assigns[:dyk_seed] || :erlang.unique_integer()

    socket
    |> assign(
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
      house_rules: load_own_house_rules(game, user),
      community_house_rules: RuleMaven.HouseRules.community_for_game(game.id, user && user.id),
      hr_card_open: socket.assigns[:hr_card_open] || true,
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
    |> then(fn s -> if s.assigns[:expansion_deltas], do: s, else: assign(s, :expansion_deltas, []) end)
    |> then(fn s -> if s.assigns[:checklist_done], do: s, else: assign(s, :checklist_done, MapSet.new()) end)
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
    quiz_idx = min(Map.get(snap, :quiz_idx, 0), length(socket.assigns.quiz))
    turn_last = max(length(socket.assigns.turn_flow) - 1, 0)

    assign(socket,
      tool_states: states,
      tool_order: order,
      quiz_idx: quiz_idx,
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

  # … handle_tool_event/3 clauses: every moved handler, body verbatim from
  # show.ex, with `assign(socket, …)` results piped through `persist/1` for
  # the @session_keys mutations (window events, quiz_*, turn_*, fp roll).
  # Checklist events keep push_checklist_save (moved here). House-rule
  # handlers keep flash + refresh_house_rules (lists only — NO load_hr_overlay).
end
```

Show changes:

1. Delete moved handlers (`show.ex:675-806` window/quiz/turn/checklist blocks, `810-913` house-rule block **except** `house_rule_delta` which stays — it needs the active thread) and moved private loaders/helpers (`load_*` at 4779-4854, `safe_tool_id`/`update_tool_state`/`set_tool_state`/`bump_order` at 4856-4903, `fact_card`/`dyk_card_for` at 4930-4942, `push_checklist_save`, `load_own_house_rules`, `refresh_house_rules` list-part). Keep `load_hr_overlay`, `get_question_log_by_id`, `load_expansion_deltas` callers now point at ToolHost.
2. Add delegation clause where the window-event block was:

```elixir
@hr_overlay_events ~w(add_house_rule edit_house_rule delete_house_rule
                      toggle_house_rule_visibility recheck_house_rule block_house_rule)

def handle_event(event, params, socket) when event in unquote(RuleMavenWeb.GameLive.ToolHost.events()) do
  {:noreply, socket} = ToolHost.handle_tool_event(event, params, socket)
  socket = if event in @hr_overlay_events, do: load_hr_overlay(socket), else: socket
  {:noreply, socket}
end
```

(If `unquote` at clause head is awkward, use `@tool_events ToolHost.events()` module attribute + `when event in @tool_events`.)

3. `do_handle_params` big assign block (`show.ex:271-322`): remove all tool keys listed in mount_tools. After the block add:

```elixir
socket = if seeded_before, do: socket, else: ToolHost.mount_tools(socket, game)
```

4. Remaining references: `fact_card` at 1269/2404 → `ToolHost.fact_card`; `load_did_you_know` in any per-patch path stays first-load-only now (verify dyk PubSub subscribe still happens — it's inside `load_did_you_know`; check and keep subscription behavior on first load); `load_expansion_deltas` at 282/662/2238 → `ToolHost.load_expansion_deltas`.

- [ ] **Step 4:** `mix compile --warnings-as-errors`, then run new + regression tests → PASS
- [ ] **Step 5:** commit `refactor: extract ToolHost; tool windows survive thread patches`

---

### Task 3: Community page gets sub-bar + tools

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/community.ex` (mount, render header `:390-401`, root)
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (`on_game_page` attr)
- Test: extend `test/rule_maven_web/live/community_live_test.exs`

**Interfaces:**
- Consumes: `ToolHost.mount_tools/2`, `ToolHost.events/0`, `ToolPanel.tool_panel/1`, `SubBar.sub_bar/1`.
- Produces: sub-bar + tool panel on `/games/:id/community`.

- [ ] **Step 1: failing test** (community_live_test.exs additions)

```elixir
test "community page shows the tool sub-bar and opens tools", %{conn: conn, game: game} do
  {:ok, view, html} = live(conn, ~p"/games/#{game}/community")
  assert html =~ "tool-subbar"
  refute html =~ "Admin Review →"
  view |> element("button[phx-click=open_tool][phx-value-tool=timer]") |> render_click()
  assert has_element?(view, "#tool-panel-timer")
end
```

- [ ] **Step 2:** run → FAIL
- [ ] **Step 3: implement**

`community.ex` mount_game: add

```elixir
sources = Games.list_documents(game)

socket =
  assign(socket,
    …existing…,
    sources: sources,
    community_count: RuleMaven.Faq.community_count(game),
    coarse_pointer: connected?(socket) and get_connect_params(socket)["coarse_pointer"] == true
  )

socket = RuleMavenWeb.GameLive.ToolHost.mount_tools(socket, game)
```

Delegating clause (top of handle_event section):

```elixir
@tool_events RuleMavenWeb.GameLive.ToolHost.events()
def handle_event(event, params, socket) when event in @tool_events,
  do: RuleMavenWeb.GameLive.ToolHost.handle_tool_event(event, params, socket)
```

Render: replace the back/Admin-Review row (`community.ex:389-401`) with

```heex
<div style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;flex-wrap:wrap;margin-bottom:1rem">
  <.link navigate={~p"/games/#{@game}"} class="back-link" style="margin-bottom:0">
    &larr; Back to {@game.name}
  </.link>
  <SubBar.sub_bar
    game={@game}
    sources={@sources}
    community_count={@community_count}
    is_admin={@is_admin}
    on_game_page={false}
  />
</div>
```

and add `<ToolPanel.tool_panel {assigns} />` as the last child of the render (outside the max-width container). Add aliases `RuleMavenWeb.GameLive.{SubBar, ToolPanel, ToolHost}`.

`sub_bar.ex`: add `attr :on_game_page, :boolean, default: true`, pass through to `more_menu`, and swap the Overview link:

```heex
<.link :if={@on_game_page} patch={~p"/games/#{@game}?start=1"} class="card-menu__item">🔍 Overview</.link>
<.link :if={!@on_game_page} navigate={~p"/games/#{@game}?start=1"} class="card-menu__item">🔍 Overview</.link>
```

Also hide the Community link when already there (`:if={@community_count > 0 and @on_game_page}` — or leave it; harmless self-link. Leave it.)

- [ ] **Step 4:** run community test + `game_live_tool_panel_test.exs` → PASS
- [ ] **Step 5:** commit `feat: sub-bar + table tools on the community page`

---

### Task 4: Cross-page window persistence

**Files:**
- Test: extend `test/rule_maven_web/live/game_live_tool_persistence_test.exs`

(Mechanism ships in Tasks 1-3; this task proves it end-to-end.)

- [ ] **Step 1: failing-or-passing test** — write it; if it already passes, keep it as the pin:

```elixir
test "windows survive navigating from game page to community and back", %{conn: conn, game: game, user: user} do
  {:ok, view, _} = live(conn, ~p"/games/#{game}")
  view |> element("button[phx-click=open_tool][phx-value-tool=timer]") |> render_click()

  {:ok, cview, _} = live(conn, ~p"/games/#{game}/community")
  assert has_element?(cview, "#tool-panel-timer")
  cview |> element("#tool-panel-timer button[phx-click=minimize_tool]") |> render_click()

  {:ok, view2, _} = live(conn, ~p"/games/#{game}")
  assert has_element?(view2, "#tool-tray [data-dock-pill=timer]")
end
```

- [ ] **Step 2:** run → expect PASS (else fix hydration)
- [ ] **Step 3:** commit `test: pin cross-page tool-window persistence`

---

### Task 5: Desktop in-flow minimized dock

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/tool_panel.ex` (split `tool_dock/1` out of `tool_panel/1`, add `dock` attr)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:4054` (render flow dock above `#chat-input-panel`, pass `dock={false}` at 4371)
- Modify: `priv/static/assets/css/app.css` (`.tool-dock--flow`)
- Modify: `priv/static/assets/js/app.js:881` (ToolTray sets `--rm-tray-h` only when fixed)

**Interfaces:**
- Produces: `ToolPanel.tool_dock(%{tool_states: map, flow: boolean})`; `tool_panel/1` accepts `dock` (default true — Community unchanged).

- [ ] **Step 1:** split component

```elixir
attr :tool_states, :map, required: true
attr :flow, :boolean, default: false

def tool_dock(assigns) do
  minimized = for {id, :minimized} <- assigns.tool_states, do: id
  assigns = assign(assigns, minimized: minimized)

  ~H"""
  <div
    :if={@minimized != []}
    id="tool-tray"
    phx-hook="ToolTray"
    class={["tool-dock", @flow && "tool-dock--flow"]}
    data-tool-dock
  >
    …existing dock inner markup verbatim…
  </div>
  """
end
```

`tool_panel/1`: drop the dock markup, add `dock` handling: at the end render `<.tool_dock :if={@dock} tool_states={@tool_states} />`. Show: `<ToolPanel.tool_panel {assigns} dock={false} />`? — `{assigns}` spread + literal attr conflicts; instead assign `dock: false` via wrapper: give `tool_panel` `attr :dock, :boolean, default: true` and have Show render `<ToolPanel.tool_panel {Map.put(assigns, :dock, false)} />`. Community uses plain `{assigns}` (dock stays fixed).

Show chat column, immediately before `<div id="chat-input-panel"…>`:

```heex
<ToolPanel.tool_dock tool_states={@tool_states} flow={true} />
```

- [ ] **Step 2:** CSS (append near `.tool-dock` rules, ~app.css:2955)

```css
/* In-flow variant: on desktop the minimized bar is a normal row above the
   composer — the messages area shrinks instead of being overlaid. Under
   640px the base fixed-strip rules still apply (bottom sheet must not bury
   the pills). */
@media (min-width: 641px) {
  .tool-dock--flow {
    position: static;
    bottom: auto;
    z-index: auto;
    padding: 0.3rem 0 0;
    pointer-events: auto;
  }
  .tool-dock--flow .tool-dock__inner { padding: 0 1rem; }
}
```

- [ ] **Step 3:** JS — ToolTray only owns `--rm-tray-h` while fixed:

```js
Hooks.ToolTray = {
  mounted() {
    var self = this;
    ToolLayout.acquire();
    this._ro = new ResizeObserver(function() {
      // In-flow dock (desktop) takes real layout space; only the fixed strip
      // needs to reserve room under the floating panels.
      if (getComputedStyle(self.el).position !== "fixed") {
        document.documentElement.style.removeProperty("--rm-tray-h");
        return;
      }
      var h = self.el.getBoundingClientRect().height;
      document.documentElement.style.setProperty("--rm-tray-h", h + "px");
    });
    this._ro.observe(this.el);
  },
  destroyed() { …unchanged… }
};
```

- [ ] **Step 4:** run `game_live_tool_panel_test.exs` + tool persistence test → PASS (dock ids/selectors unchanged)
- [ ] **Step 5:** browser verify (major UI change): desktop — minimize a tool, bar sits above composer in flow, messages scroll; 390px — fixed strip + sheet behavior unchanged; community page dock still fixed.
- [ ] **Step 6:** commit `feat: desktop minimized tool bar sits in flow above the composer`

---

### Task 6: Verification sweep

- [ ] `mix compile --warnings-as-errors`
- [ ] Run: table_session, tool_persistence, tool_panel, turn_wizard, house_rules, community_live, landing_overview tests (tee to ./tmp/subbar-tests.log)
- [ ] Puppeteer: game page desktop + 390px, community page desktop + 390px; open/minimize tools; navigate game↔community; More→Overview from community (must full-navigate, not crash)
- [ ] Update /help guide + tours if the sub-bar's reach changed user-facing docs (standing rule)
- [ ] Commit any fixes; merge worktree → master, delete branch, remove worktree (hard rule; no push)
