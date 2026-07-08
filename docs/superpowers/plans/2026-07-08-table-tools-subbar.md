# Table Tools sub-bar + floating tool panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the game page's 10-card empty-state dump with a persistent Play/Learn/More sub-bar that launches every table tool into a shared, movable, state-preserving floating panel reachable at any time.

**Architecture:** A tool registry drives both a slim persistent sub-bar (three group menus) and a shared floating-panel host. Panel visibility is a server-side state machine (`@tool_states`: one `:expanded`, many `:minimized`); each tool's own state already lives in socket assigns so closing never resets it. A `FloatingPanel` JS hook makes the expanded panel a draggable card on fine-pointer devices and a bottom sheet on coarse-pointer (mobile), with a peek-pill dock for minimized tools.

**Tech Stack:** Phoenix LiveView (HEEx function components), vanilla JS LiveView hooks in `priv/static/assets/js/app.js` (no build step — edit the committed file directly), ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- **Mobile-first (hard rule):** every UI change must look good and work at 390px. Verify with the Puppeteer 390px sweep before completion.
- **Buttons:** use shared `btn-*` classes (`btn-primary`, `btn-outline`, `btn-xs`, `btn-icon`), never fresh inline button styles. One primary per row.
- **Contrast:** any new color pair must clear WCAG floors enforced by existing contrast tests (labels-on-accent 7:1, muted 4.5:1).
- **No raw ids in URLs:** links use `RuleMaven.Hashid` tokens (already the norm on this page); `phx-value` ids stay raw.
- **Run only necessary tests:** run only the test files touched/added here, one representative test per mechanism. No full suite.
- **Help + tours upkeep (standing rule):** user-facing feature changes update `/help` guide + FAQ and the affected tours.
- **Theme vars:** colors come from CSS vars (`--accent`, `--bg-surface`, `--border`, `--text`, `--text-muted`, `--accent-ink`), never hardcoded hex except existing fallbacks.
- **Target file:** `lib/rule_maven_web/live/game_live/show.ex` (~5600 lines). Do not grow it — extract new markup into sibling modules under `lib/rule_maven_web/live/game_live/`.

---

## Tool inventory (source of truth for the registry)

Current empty-state tool blocks in `show.ex` (verbatim relocation targets — line numbers are approximate, match on the leading comment/emoji):

| id | emoji | label | group | source lines (approx) | state assigns | notes |
|----|-------|-------|-------|-----------------------|---------------|-------|
| `dyk` | 💡 | Did you know | learn | 3132–3157 (empty-state card) | `rule_card` | also has slim sticky variant 3053–3065 (leave that in place) |
| `first_player` | 🎲 | Who goes first | play | 3194–3220 | `fp_selectors`, `fp_pick` | |
| `turn` | 🕹️ | Turn Wizard | play | 3222–3279 | `turn_flow`, `turn_phase`, `turn_open` | wrapped in `<details>` — unwrap on move |
| `teach` | ⚡ | Teach it in 60s | learn | 3281–3313 | `teach_pitch` | `<details>` + `ReadAloud` hook |
| `mistakes` | ⚠️ | Rules tables get wrong | learn | 3315–3338 | `common_mistakes` | `<details>` |
| `quiz` | 🎓 | Rules quiz | learn | 3340–3412 | `quiz`, `quiz_idx`, `quiz_choice`, `quiz_score` | `<details>` |
| `scorepad` | 🏆 | Score pad | play | 3414–3432 | `score_categories` | `phx-update="ignore"` + `ScorePad` hook (localStorage) |
| `timer` | ⏱️ | Turn timer | play | 3434–3484 | (client-only) | `phx-update="ignore"` + `TurnTimer` hook; in-memory countdown is **ephemeral** — resets when panel closed (documented v1 limitation) |
| `checklist` | 🧩 | Setup checklist | play | 3486–3580 | `setup_checklist`, `checklist_done`, `expansion_deltas` | `ChecklistStore` hook (localStorage) |
| `house_rules` | 🏠 | House rules | learn | 3582–~3760 | `house_rules`, `community_house_rules`, `hr_card_open`, `hr_form_open`, `hr_editing_id` | many events; unwrap the `toggle_house_rules_card` accordion — panel is the container |

**More group (nav links, not panel tools):** Community Q&A (`~p"/games/#{@game}/community"`), Rulebooks (existing sources dropdown markup 2743–2782), Cheat Sheet (`~p"/games/#{@game}/cheatsheet"`), Overview (`~p"/games/#{@game}?start=1"`), BGG (external), 🖌️ Dress in colors (`GameThemeHint` button 3121–3130). These render inside the More menu and navigate/act as they do today.

---

## File structure

- **Create** `lib/rule_maven_web/live/game_live/tool_registry.ex` — `RuleMavenWeb.GameLive.ToolRegistry`. Static list of tool descriptors + helpers. No LiveView state.
- **Create** `lib/rule_maven_web/live/game_live/sub_bar.ex` — `RuleMavenWeb.GameLive.SubBar`. Function component rendering the three group menus.
- **Create** `lib/rule_maven_web/live/game_live/tool_panel.ex` — `RuleMavenWeb.GameLive.ToolPanel`. Function components: the panel host, the dock, and one `render_tool/1` clause per tool (relocated markup).
- **Modify** `lib/rule_maven_web/live/game_live/show.ex` — add `@tool_states` assign + 4 events; render `SubBar` + `ToolPanel`; delete the 10 relocated blocks from the empty state.
- **Modify** `priv/static/assets/js/app.js` — add `Hooks.FloatingPanel`.
- **Modify** `lib/rule_maven_web/tours.ex` (or wherever `data-tour` anchors/tour steps live) — repoint moved anchors.
- **Modify** the `/help` guide/FAQ template — document the sub-bar.
- **Create** `test/rule_maven_web/live/game_live_tool_panel_test.exs` — state-machine + resume tests.

---

## Task 1: Tool registry module

**Files:**
- Create: `lib/rule_maven_web/live/game_live/tool_registry.ex`
- Test: `test/rule_maven_web/live/game_live_tool_registry_test.exs`

**Interfaces:**
- Produces:
  - `ToolRegistry.tools() :: [tool]` where `tool :: %{id: atom, emoji: String.t, label: String.t, group: :play | :learn | :learn}`
  - `ToolRegistry.group(:play | :learn) :: [tool]` — tools in a group, in display order
  - `ToolRegistry.tool(id :: atom) :: tool | nil`
  - `ToolRegistry.ids() :: [atom]` — all valid tool ids
  - `ToolRegistry.valid?(id :: atom) :: boolean`

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/game_live_tool_registry_test.exs`:

```elixir
defmodule RuleMavenWeb.GameLive.ToolRegistryTest do
  use ExUnit.Case, async: true
  alias RuleMavenWeb.GameLive.ToolRegistry

  test "every tool has the required keys and a known group" do
    for t <- ToolRegistry.tools() do
      assert is_atom(t.id)
      assert is_binary(t.emoji) and t.emoji != ""
      assert is_binary(t.label) and t.label != ""
      assert t.group in [:play, :learn]
    end
  end

  test "ids are unique" do
    ids = ToolRegistry.ids()
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "group/1 returns only tools of that group" do
    assert Enum.all?(ToolRegistry.group(:play), &(&1.group == :play))
    assert Enum.all?(ToolRegistry.group(:learn), &(&1.group == :learn))
  end

  test "valid?/1 and tool/1 agree" do
    assert ToolRegistry.valid?(:turn)
    refute ToolRegistry.valid?(:nope)
    assert ToolRegistry.tool(:turn).emoji == "🕹️"
    assert ToolRegistry.tool(:nope) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live_tool_registry_test.exs`
Expected: FAIL — `RuleMavenWeb.GameLive.ToolRegistry` is undefined.

- [ ] **Step 3: Write the module**

Create `lib/rule_maven_web/live/game_live/tool_registry.ex`:

```elixir
defmodule RuleMavenWeb.GameLive.ToolRegistry do
  @moduledoc """
  Static descriptor list for the table-tools sub-bar. Drives both the
  Play/Learn group menus (SubBar) and the shared floating panel (ToolPanel).
  Per-tool *state* lives in the LiveView's socket assigns, not here — this is
  presentation metadata only. Adding a tool is one entry here plus a
  `render_tool/1` clause in ToolPanel.
  """

  @tools [
    # Play — do it at the table now
    %{id: :turn, emoji: "🕹️", label: "Turn Wizard", group: :play},
    %{id: :first_player, emoji: "🎲", label: "Who goes first", group: :play},
    %{id: :checklist, emoji: "🧩", label: "Setup checklist", group: :play},
    %{id: :scorepad, emoji: "🏆", label: "Score pad", group: :play},
    %{id: :timer, emoji: "⏱️", label: "Turn timer", group: :play},
    # Learn — understand this game
    %{id: :teach, emoji: "⚡", label: "Teach it in 60s", group: :learn},
    %{id: :quiz, emoji: "🎓", label: "Rules quiz", group: :learn},
    %{id: :mistakes, emoji: "⚠️", label: "Rules tables get wrong", group: :learn},
    %{id: :dyk, emoji: "💡", label: "Did you know", group: :learn},
    %{id: :house_rules, emoji: "🏠", label: "House rules", group: :learn}
  ]

  def tools, do: @tools
  def ids, do: Enum.map(@tools, & &1.id)
  def group(g), do: Enum.filter(@tools, &(&1.group == g))
  def tool(id), do: Enum.find(@tools, &(&1.id == id))
  def valid?(id), do: Enum.any?(@tools, &(&1.id == id))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/game_live_tool_registry_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/tool_registry.ex test/rule_maven_web/live/game_live_tool_registry_test.exs
git commit -m "feat: table-tools registry"
```

---

## Task 2: Panel state machine + events in show.ex

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (add `tool_states` to the mount assigns near line 291–297; add 4 `handle_event/3` clauses near the other UI events, e.g. after `quiz_restart` ~line 693)
- Test: `test/rule_maven_web/live/game_live_tool_panel_test.exs`

**Interfaces:**
- Produces (socket assign): `@tool_states :: %{optional(atom) => :expanded | :minimized}` — invariant: at most one `:expanded`.
- Produces (events): `"open_tool"`, `"expand_tool"`, `"minimize_tool"`, `"close_tool"`, each taking `%{"tool" => id_string}`.
- Consumes: `ToolRegistry.valid?/1` from Task 1.

Helper (put it as a private fn in `show.ex`):

```elixir
# At most one tool may be :expanded. Demote whoever is currently expanded to
# :minimized, then set `id` to `state`. Invalid ids are ignored (defensive:
# events come from the client).
defp set_tool_state(states, id, state) do
  states
  |> Enum.map(fn
    {k, :expanded} when k != id -> {k, :minimized}
    other -> other
  end)
  |> Map.new()
  |> Map.put(id, state)
end
```

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/game_live_tool_panel_test.exs`:

```elixir
defmodule RuleMavenWeb.GameLiveToolPanelTest do
  @moduledoc """
  The table-tools panel is a server-side state machine: `@tool_states` maps a
  tool id to :expanded | :minimized, with at most one :expanded. Opening a
  second tool demotes the first to the dock; each tool's own state (quiz score,
  etc.) survives close because it lives in separate assigns.
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "toolpanel_user",
        email: "toolpanel_user@test.com",
        password: "password1234"
      })

    u
  end

  defp seed_tools(game) do
    RuleMaven.Settings.put(
      "turn_flow_#{game.id}",
      Jason.encode!([%{"name" => "Roll", "note" => "", "actions" => []}])
    )

    RuleMaven.Settings.put(
      "quiz_#{game.id}",
      Jason.encode!([
        %{"q" => "Q1?", "choices" => ["a", "b"], "answer" => 0, "why" => "because"}
      ])
    )
  end

  defp open_view(conn) do
    u = user()
    game = published_game_fixture(%{name: "Tool Panel Game"})
    seed_tools(game)
    conn = login(conn, u)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    view
  end

  test "opening a second tool demotes the first to minimized", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "open_tool", %{"tool" => "quiz"})

    # Both present; exactly one expanded panel, one dock pill.
    html = render(view)
    assert html =~ ~s(data-tool-state="expanded")
    assert html =~ ~s(data-tool-panel="quiz")
    # turn is now a dock pill
    assert html =~ ~s(data-dock-pill="turn")
  end

  test "quiz score survives close and re-open", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "quiz"})
    render_click(view, "quiz_answer", %{"choice" => "0"})
    render_click(view, "close_tool", %{"tool" => "quiz"})
    html = render_click(view, "open_tool", %{"tool" => "quiz"})

    # asked count is preserved (1), not reset to 0
    assert html =~ "Score 1/1"
  end

  test "invalid tool id is ignored", %{conn: conn} do
    view = open_view(conn)
    html = render_click(view, "open_tool", %{"tool" => "bogus"})
    refute html =~ ~s(data-tool-panel="bogus")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live_tool_panel_test.exs`
Expected: FAIL — events `open_tool`/`close_tool` not handled (or `data-tool-panel` absent). (Task 3 adds the markup the assertions read; this task adds the events. Expect failures on missing events first.)

- [ ] **Step 3: Add the assign and events to show.ex**

In the mount assign list (after `quiz_score: {0, 0},` ~line 297) add:

```elixir
        tool_states: %{},
```

Add these `handle_event/3` clauses (place after the `quiz_restart` handler ~line 693). `alias RuleMavenWeb.GameLive.ToolRegistry` at the top of the module if not present:

```elixir
  def handle_event("open_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :expanded)}
  end

  def handle_event("expand_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :expanded)}
  end

  def handle_event("minimize_tool", %{"tool" => tool}, socket) do
    {:noreply, update_tool_state(socket, tool, :minimized)}
  end

  def handle_event("close_tool", %{"tool" => tool}, socket) do
    id = safe_tool_id(tool)

    states =
      if id, do: Map.delete(socket.assigns.tool_states, id), else: socket.assigns.tool_states

    {:noreply, assign(socket, :tool_states, states)}
  end
```

Add these private helpers (near the bottom, by the other private fns):

```elixir
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
      nil -> socket
      id -> assign(socket, :tool_states, set_tool_state(socket.assigns.tool_states, id, state))
    end
  end

  defp set_tool_state(states, id, state) do
    states
    |> Enum.map(fn
      {k, :expanded} when k != id -> {k, :minimized}
      other -> other
    end)
    |> Map.new()
    |> Map.put(id, state)
  end
```

(Do not run the test to pass yet — the markup assertions land in Task 3. Verify compilation only.)

- [ ] **Step 4: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean (unused `set_tool_state`/events warnings are acceptable only until Task 3 wires them; if `--warnings-as-errors` blocks, proceed to Task 3 before committing, or temporarily commit with `mix compile`).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live_tool_panel_test.exs
git commit -m "feat: table-tools panel state machine + events"
```

---

## Task 3: ToolPanel + SubBar components; relocate tool markup; declutter empty state

This is the largest task: it moves the 10 tool blocks out of the empty state into `ToolPanel`, adds the host + dock, and adds the `SubBar`. Do it tool-by-tool to keep each move verifiable, but it lands as one reviewable task (the page is broken in between).

**Files:**
- Create: `lib/rule_maven_web/live/game_live/tool_panel.ex`
- Create: `lib/rule_maven_web/live/game_live/sub_bar.ex`
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (render the two components; delete relocated blocks 3132–~3760)

**Interfaces:**
- Consumes: `@tool_states` (Task 2), `ToolRegistry` (Task 1), and every tool-state assign listed in the inventory table.
- Produces (markup contract the Task 2 test asserts):
  - expanded panel wrapper carries `data-tool-panel={id}` and `data-tool-state="expanded"`
  - each minimized tool renders a dock pill with `data-dock-pill={id}`

- [ ] **Step 1: Create the SubBar component**

Create `lib/rule_maven_web/live/game_live/sub_bar.ex`. It needs the assigns used by the More-group links (`@game`, `@sources`, `@community_count`, `@is_admin`, `@current_user`). Reuse the existing `card-menu` classes.

```elixir
defmodule RuleMavenWeb.GameLive.SubBar do
  @moduledoc """
  Persistent slim sub-bar under the game header. Three group menus
  (🎲 Play · 📚 Learn · 💬 More); Play/Learn items dispatch `open_tool`,
  More items are navigation/links. Always rendered (empty state AND
  mid-conversation) so tools stay reachable. Mobile-first: one row, three
  short pills fit 390px.
  """
  use RuleMavenWeb, :html
  alias RuleMavenWeb.GameLive.ToolRegistry

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :current_user, :map, required: true

  def sub_bar(assigns) do
    ~H"""
    <div
      class="tool-subbar"
      style="flex-shrink:0;display:flex;align-items:center;gap:0.4rem;padding:0.25rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface);overflow-x:auto"
    >
      <.group_menu emoji="🎲" label="Play" tools={ToolRegistry.group(:play)} />
      <.group_menu emoji="📚" label="Learn" tools={ToolRegistry.group(:learn)} />
      <.more_menu
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :emoji, :string, required: true
  attr :label, :string, required: true
  attr :tools, :list, required: true

  defp group_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <summary
        class="pill-link"
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">{@emoji}</span>
        <span>{@label}</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div class="card-menu__pop">
        <button
          :for={t <- @tools}
          type="button"
          phx-click="open_tool"
          phx-value-tool={t.id}
          onclick="this.closest('details').open = false"
          class="card-menu__item"
        >
          <span aria-hidden="true">{t.emoji}</span> {t.label}
        </button>
      </div>
    </details>
    """
  end

  attr :game, :map, required: true
  attr :sources, :list, required: true
  attr :community_count, :integer, required: true
  attr :is_admin, :boolean, required: true
  attr :current_user, :map, required: true

  defp more_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <summary
        class="pill-link"
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">💬</span>
        <span>More</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div class="card-menu__pop card-menu__pop--right">
        <.link patch={~p"/games/#{@game}?start=1"} class="card-menu__item">🔍 Overview</.link>
        <.link
          :if={@community_count > 0}
          navigate={~p"/games/#{@game}/community"}
          class="card-menu__item"
        >💬 Community Q&amp;A ({@community_count})</.link>
        <%= if @sources != [] do %>
          <div class="card-menu__divider"></div>
          <div class="card-menu__label">📖 Rulebooks</div>
          <%= for src <- @sources do %>
            <%= if @is_admin and src.html_path do %>
              <.link href={~p"/rulebooks/#{src}/html"} target="_blank" class="card-menu__item">
                {src.label}
              </.link>
            <% else %>
              <div class="card-menu__item" style="cursor:default">{src.label}</div>
            <% end %>
          <% end %>
        <% end %>
        <.link
          :if={@game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(@game.category)}
          href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
          target="_blank"
          rel="noopener"
          class="card-menu__item"
        >🔗 View on BGG</.link>
      </div>
    </details>
    """
  end
end
```

- [ ] **Step 2: Create the ToolPanel host + dock skeleton**

Create `lib/rule_maven_web/live/game_live/tool_panel.ex`. Start with the host, dock, and a placeholder `render_tool/1` for one tool (`turn`) to prove the contract; remaining tools are added in Step 4. The host takes the **whole `assigns`** (it needs every tool's state) — pass `assigns` straight through.

```elixir
defmodule RuleMavenWeb.GameLive.ToolPanel do
  @moduledoc """
  Shared host for every table tool. Renders the currently-:expanded tool as a
  floating panel (draggable card on desktop, bottom sheet on mobile — behavior
  supplied by the FloatingPanel JS hook) plus a dock of peek pills for
  :minimized tools. Tool *content* is relocated verbatim from show.ex; the only
  new markup is the panel chrome (drag handle, minimize/close) and the dock.

  Visibility is driven by `@tool_states` (see Show: open_tool/minimize_tool/
  close_tool/expand_tool). Each tool's own state lives in the passed assigns, so
  closing a panel never resets it.
  """
  use RuleMavenWeb, :html
  alias RuleMavenWeb.GameLive.ToolRegistry

  # `assigns` is the full LiveView assigns map (needs every tool's state).
  def tool_panel(assigns) do
    expanded = Enum.find_value(assigns.tool_states, fn {id, s} -> s == :expanded && id end)
    minimized = for {id, :minimized} <- assigns.tool_states, do: id
    assigns = assign(assigns, expanded: expanded, minimized: minimized)

    ~H"""
    <div :if={@expanded} data-tool-panel={@expanded} data-tool-state="expanded">
      <.panel_frame id={@expanded}>
        {render_tool(assign(assigns, :tool, @expanded))}
      </.panel_frame>
    </div>

    <div :if={@minimized != []} class="tool-dock" data-tool-dock>
      <button
        :for={id <- @minimized}
        type="button"
        data-dock-pill={id}
        phx-click="expand_tool"
        phx-value-tool={id}
        class="tool-dock__pill"
      >
        <span aria-hidden="true">{ToolRegistry.tool(id).emoji}</span>
        {ToolRegistry.tool(id).label}
      </button>
    </div>
    """
  end

  attr :id, :atom, required: true
  slot :inner_block, required: true

  defp panel_frame(assigns) do
    tool = ToolRegistry.tool(assigns.id)
    assigns = assign(assigns, :tool, tool)

    ~H"""
    <div
      id={"tool-panel-#{@id}"}
      phx-hook="FloatingPanel"
      data-tool={@id}
      class="tool-panel"
    >
      <div class="tool-panel__bar" data-drag-handle>
        <span class="tool-panel__title">
          <span aria-hidden="true">{@tool.emoji}</span> {@tool.label}
        </span>
        <span class="tool-panel__controls">
          <button
            type="button"
            phx-click="minimize_tool"
            phx-value-tool={@id}
            class="btn-icon btn-sm"
            title="Minimize"
            aria-label="Minimize"
          >–</button>
          <button
            type="button"
            phx-click="close_tool"
            phx-value-tool={@id}
            class="btn-icon btn-sm"
            title="Close"
            aria-label="Close"
          >✕</button>
        </span>
      </div>
      <div class="tool-panel__body">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # One clause per tool. Content is the relocated markup from show.ex, with the
  # outer <details>/<summary>/card wrapper stripped (panel_frame is the container
  # + title). Added tool-by-tool in Step 4.
  defp render_tool(%{tool: :turn} = assigns) do
    ~H"""
    <p>turn placeholder</p>
    """
  end

  defp render_tool(assigns) do
    ~H"""
    <p style="color:var(--text-muted)">Tool coming soon.</p>
    """
  end
end
```

- [ ] **Step 3: Wire both components into show.ex**

At the top of `show.ex`'s render (after the header block ~line 2834, before the `<div style="display:flex;flex:1;min-height:0">` at 2836) insert the sub-bar:

```elixir
      <RuleMavenWeb.GameLive.SubBar.sub_bar
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        current_user={@current_user}
      />
```

Just before the closing of the chat-messages/input container (place the panel host as a sibling of the input panel, e.g. right after the `</div>` that closes `chat-input-panel` ~line 4703 region — it renders fixed/floating so DOM position is not critical, but keep it inside the chat-layout root), insert:

```elixir
      <RuleMavenWeb.GameLive.ToolPanel.tool_panel {assigns} />
```

Add `alias RuleMavenWeb.GameLive.{SubBar, ToolPanel}` near the top if you prefer short names.

- [ ] **Step 4: Relocate each tool's markup into `render_tool/1`**

For **each** tool in the inventory table, in order, do this micro-cycle:

1. Cut the tool's markup block from `show.ex` at the listed lines.
2. Paste it as the body of a new `defp render_tool(%{tool: :ID} = assigns)` clause in `tool_panel.ex`, **removing** the outer `<details>`/`<summary>` or card `<div>`/accordion-toggle wrapper (the panel frame supplies container + title). Keep all inner controls, `phx-click`s, `phx-hook`s, `:if`/`:for`, and CSS-var styles exactly.
3. Where the block referenced a `<summary phx-click="turn_toggle">` or `toggle_house_rules_card` accordion to show/hide content, delete that toggle — the content is always shown inside the panel. (Leave the underlying events defined in `show.ex`; simply stop rendering the toggle. `turn_open`/`hr_card_open` assigns become inert — safe to leave.)
4. For `dyk`: relocate the full empty-state card (3132–3157). **Leave** the slim sticky variant (3053–3065) untouched.
5. `mix compile` — fix any missing-assign errors (the panel already receives full `assigns`, so all `@rule_card`, `@quiz`, etc. resolve).
6. Move to the next tool.

Notes for the three `phx-update="ignore"` tools:
- `scorepad`, `timer`, `checklist`: keep their inner `id=`, `phx-hook=`, `phx-update="ignore"`, and `data-*` attributes verbatim. Because the panel mounts on expand and unmounts on close, the hook re-inits from localStorage on each open — correct for ScorePad/ChecklistStore. For `timer`, the in-memory countdown resets on close; that is the documented v1 limitation (no change needed).
- `checklist` also uses the `.checklist_item` and (house_rules) `.house_rule_row` function components. Those are defined in `show.ex`. **Import them** into `ToolPanel` or move them alongside. Simplest: change their `defp` to `def` in `show.ex` and call as `RuleMavenWeb.GameLive.Show.checklist_item/1`? No — function components can't be shared as private. **Action:** move `checklist_item/1` and `house_rule_row/1` (and any helper they call that is pure formatting, e.g. `clean_rule_text/1`, `teach_speech/1`) into a shared `RuleMavenWeb.GameLive.ToolHelpers` module, `import` it in both `show.ex` and `tool_panel.ex`. If a helper needs event handlers, those stay in `show.ex` (events are module-level, resolved by the LiveView regardless of which module rendered the markup).

- [ ] **Step 5: Delete the now-empty empty-state tool region & confirm the empty state**

After all 10 blocks are moved, the empty-state `<div class="answer-in">` (from ~3069) should retain only: game hero image/name, BGG stats row, difficulty, the intro paragraph, the "Dress in colors" button (or move it to the More menu — keep it here for now), and the suggested-questions/ask affordance. Remove leftover empty `<%= if ... do %>` shells for moved tools.

- [ ] **Step 6: Run the panel test to verify it now passes**

Run: `mix test test/rule_maven_web/live/game_live_tool_panel_test.exs`
Expected: PASS (3 tests) — the `data-tool-panel`, `data-dock-pill`, and "Score 1/1" assertions are now satisfied.

- [ ] **Step 7: Run the existing tool tests that touched moved markup**

Run: `mix test test/rule_maven_web/live/game_live_turn_wizard_test.exs test/rule_maven_web/live/game_live_house_rules_test.exs test/rule_maven_web/live/game_live_landing_overview_test.exs`
Expected: these will likely FAIL where they assumed empty-state rendering or the `<details open>` wrapper. Update each assertion to open the tool first (`render_click(view, "open_tool", %{"tool" => "turn"})`) then assert content; drop the `<details open>` regex (panel has no `<details>`). Fix the tests to match the new UX — do not weaken them. Re-run until green.

- [ ] **Step 8: Commit**

```bash
git add lib/rule_maven_web/live/game_live/tool_panel.ex \
        lib/rule_maven_web/live/game_live/sub_bar.ex \
        lib/rule_maven_web/live/game_live/tool_helpers.ex \
        lib/rule_maven_web/live/game_live/show.ex \
        test/rule_maven_web/live/game_live_turn_wizard_test.exs \
        test/rule_maven_web/live/game_live_house_rules_test.exs \
        test/rule_maven_web/live/game_live_landing_overview_test.exs
git commit -m "feat: relocate table tools into shared floating panel + sub-bar"
```

---

## Task 4: FloatingPanel JS hook (drag / sheet / persist)

**Files:**
- Modify: `priv/static/assets/js/app.js` (add `Hooks.FloatingPanel` next to `Hooks.ChecklistStore` ~line 776; hooks auto-register from the `Hooks` object already wired into `LiveSocket`)
- Modify: add CSS for `.tool-panel`, `.tool-panel__bar`, `.tool-dock`, `.tool-dock__pill`, `.tool-subbar` (locate the stylesheet the app uses — search for `.card-menu__pop {` to find the same file, likely `priv/static/assets/css/app.css`; add rules there).

**Interfaces:**
- Consumes: DOM contract from Task 3 — `#tool-panel-<id>`, `[data-drag-handle]`, `[data-tool]`.
- Produces: draggable/positioned panel; persists `{x,y}` to `localStorage["rm:toolpos:"+tool]` on desktop.

- [ ] **Step 1: Add the hook**

In `priv/static/assets/js/app.js`, after `Hooks.ChecklistStore = { ... };` (line ~776) add:

```javascript
// Floating table-tool panel. Fine-pointer (desktop): a draggable card, no
// backdrop, chat stays interactive; drag by [data-drag-handle], position saved
// to localStorage per tool. Coarse-pointer (mobile): a bottom sheet, no drag.
// Minimize/close/expand are server events (phx-click in the markup); this hook
// only owns positioning.
Hooks.FloatingPanel = {
  isCoarse() {
    return window.matchMedia && window.matchMedia("(pointer:coarse)").matches;
  },
  posKey() {
    return "rm:toolpos:" + this.el.dataset.tool;
  },
  applySaved() {
    if (this.isCoarse()) return; // sheet mode ignores saved x/y
    try {
      var p = JSON.parse(localStorage.getItem(this.posKey()) || "null");
      if (p && typeof p.x === "number" && typeof p.y === "number") {
        this.el.style.left = p.x + "px";
        this.el.style.top = p.y + "px";
        this.el.style.right = "auto";
        this.el.style.bottom = "auto";
      }
    } catch (_e) {}
  },
  mounted() {
    var self = this;
    this.el.classList.toggle("tool-panel--sheet", this.isCoarse());
    this.applySaved();
    if (this.isCoarse()) return;

    var handle = this.el.querySelector("[data-drag-handle]");
    if (!handle) return;
    this._down = function(e) {
      // ignore drags that start on a control button
      if (e.target.closest("button")) return;
      var rect = self.el.getBoundingClientRect();
      var offX = e.clientX - rect.left;
      var offY = e.clientY - rect.top;
      function move(ev) {
        var x = Math.max(0, Math.min(window.innerWidth - 40, ev.clientX - offX));
        var y = Math.max(0, Math.min(window.innerHeight - 40, ev.clientY - offY));
        self.el.style.left = x + "px";
        self.el.style.top = y + "px";
        self.el.style.right = "auto";
        self.el.style.bottom = "auto";
      }
      function up() {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
        var r = self.el.getBoundingClientRect();
        try {
          localStorage.setItem(self.posKey(), JSON.stringify({ x: r.left, y: r.top }));
        } catch (_e) {}
      }
      document.addEventListener("mousemove", move);
      document.addEventListener("mouseup", up);
      e.preventDefault();
    };
    handle.addEventListener("mousedown", this._down);
    this._handle = handle;
  },
  destroyed() {
    if (this._handle && this._down) this._handle.removeEventListener("mousedown", this._down);
  }
};
```

- [ ] **Step 2: Add the CSS**

In the app stylesheet (same file as `.card-menu__pop`), add:

```css
.tool-subbar { scrollbar-width: none; }
.tool-subbar::-webkit-scrollbar { display: none; }

/* Desktop: floating card, no backdrop, chat stays live. */
.tool-panel {
  position: fixed;
  right: 1rem;
  bottom: 5rem;
  width: min(30rem, calc(100vw - 2rem));
  max-height: 70vh;
  overflow: auto;
  z-index: 60;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 0.75rem;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
}
.tool-panel__bar {
  position: sticky;
  top: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  border-bottom: 1px solid var(--border);
  background: var(--bg-surface);
  cursor: grab;
  user-select: none;
}
.tool-panel__title {
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: var(--text);
}
.tool-panel__controls { display: flex; gap: 0.25rem; }
.tool-panel__body { padding: 0.85rem 1rem 1.1rem; }

/* Mobile: bottom sheet, chat visible above. */
.tool-panel--sheet {
  left: 0;
  right: 0;
  bottom: 0;
  top: auto;
  width: 100%;
  max-height: 75vh;
  border-radius: 0.9rem 0.9rem 0 0;
  cursor: default;
}
.tool-panel--sheet .tool-panel__bar { cursor: default; }

/* Dock of minimized tools. */
.tool-dock {
  position: fixed;
  right: 1rem;
  bottom: 5rem;
  display: flex;
  gap: 0.4rem;
  max-width: calc(100vw - 2rem);
  overflow-x: auto;
  z-index: 55;
}
.tool-dock__pill {
  flex-shrink: 0;
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.3rem 0.7rem;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--bg-surface);
  color: var(--text);
  font-size: 0.7rem;
  font-weight: 600;
  cursor: pointer;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.15);
}
@media (max-width: 640px) {
  .tool-dock { left: 0.5rem; right: 0.5rem; bottom: 4.5rem; }
}
```

- [ ] **Step 3: Manual verification — desktop drag + persist**

Run the app (per the run skill / `mix phx.server`), open a game with tools, open Turn Wizard from Play, drag it by the title bar, reload the page, re-open Turn Wizard → it appears at the dragged position. Chat input remains clickable while the panel is open.

- [ ] **Step 4: Manual verification — mobile sheet + dock (390px)**

Puppeteer/responsive at 390px (per mobile-support recipe): open a tool → renders as a bottom sheet, chat visible above, ask box tappable. Minimize → a pill appears in the dock; tap it → re-expands. Open a second tool → first demotes to a pill. No horizontal body scroll.

- [ ] **Step 5: Commit**

```bash
git add priv/static/assets/js/app.js priv/static/assets/css/app.css
git commit -m "feat: FloatingPanel hook — desktop drag, mobile sheet, dock"
```

---

## Task 5: Tours, help, and final verification

**Files:**
- Modify: `lib/rule_maven_web/tours.ex` (and any `data-tour="..."` anchors that moved)
- Modify: the `/help` guide + FAQ template (find via `grep -rn "FAQ" lib/rule_maven_web` — likely a `help` LiveView/controller template)

**Interfaces:** none (content only).

- [ ] **Step 1: Repoint moved tour anchors**

The game tour references `data-tour` anchors that moved into the panel: `turnwizard`, `teach`, `house-rules`, `scorepad`, plus `suggestions`/`voices` which stayed in the composer. Moved tools are no longer in the DOM until opened, so tour steps that spotlight them will break. Update `RuleMavenWeb.Tours` game steps to instead spotlight the **sub-bar** (add a `data-tour="tools-subbar"` on the `.tool-subbar` root in `sub_bar.ex`) with copy like "Every table tool lives here — tap Play or Learn." Remove the individual per-tool steps that can no longer anchor. Keep `suggestions`/`voices` steps as-is.

- [ ] **Step 2: Add the tour anchor**

In `sub_bar.ex`, add `data-tour="tools-subbar"` to the outer `.tool-subbar` div.

- [ ] **Step 3: Update /help**

Add a short "Table Tools" section to the help guide: the sub-bar groups (Play/Learn/More), that tools open as movable panels, minimize to the dock, and remember where you left off. Add one FAQ: "Where did the turn wizard / quiz / checklist go?" → "They're in the Play and Learn menus at the top of any game page."

- [ ] **Step 4: Run the touched tests + a targeted compile**

Run: `mix test test/rule_maven_web/live/game_live_tool_registry_test.exs test/rule_maven_web/live/game_live_tool_panel_test.exs test/rule_maven_web/live/game_live_turn_wizard_test.exs test/rule_maven_web/live/game_live_house_rules_test.exs test/rule_maven_web/live/game_live_landing_overview_test.exs`
Expected: all PASS. Tee output to `./tmp/tooltest.log`; delete the log when green.

- [ ] **Step 5: Contrast check**

Run the contrast test that guards color floors (find via `grep -rln "contrast" test/`), e.g. `mix test test/rule_maven_web/contrast_test.exs`.
Expected: PASS — the new pills/panel reuse existing vars, so no new pairs, but confirm.

- [ ] **Step 6: Full in-browser smoke (major behavior change → browser verification required)**

Open a fully-enriched game. Verify: empty state is now hero + ask box (+ optional dyk sticky), no 10-card stack; sub-bar present on empty state AND after asking a question; each tool opens, minimizes, docks, closes, and resumes state; desktop drag persists; 390px sheet works. Note the OpenRouter charge breakdown if any LLM calls fired (none expected — all tools are cached/finalize-time).

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/tours.ex lib/rule_maven_web/live/game_live/sub_bar.ex <help template path>
git commit -m "docs: repoint game tour + help at table-tools sub-bar"
```

---

## Self-review — spec coverage

- Persistent slim sub-bar (spec §1) → Task 3 Step 3 + SubBar (Task 3 Step 1); tour anchor Task 5.
- Group → tool mapping incl. House Rules under Learn (spec §2) → ToolRegistry (Task 1); More menu (Task 3 Step 1).
- Shared floating panel, multi-pill dock, state machine + transitions (spec §3) → `@tool_states` + events (Task 2); host + dock + `panel_frame` (Task 3 Step 2); FloatingPanel hook drag/sheet (Task 4).
- State persistence via assigns; desktop position in localStorage (spec §4) → Task 2 (close = delete key only, tool assigns untouched; test asserts resume); Task 4 posKey persistence.
- Empty state decluttered (spec §5) → Task 3 Step 5.
- Composer unchanged (spec §6) → no task touches the composer (explicit).
- Components/refactor: SubBar, ToolPanel, FloatingPanel, tool registry (spec "Components") → Tasks 1, 3, 4; plus `ToolHelpers` extraction for shared function components (Task 3 Step 4).
- New events open/expand/minimize/close (spec) → Task 2.
- Error/edge: disabled gating, admin-only, invariant defense (spec) → `safe_tool_id` ignores unknown ids (Task 2, tested); admin/nav gating preserved in More menu (Task 3); single-expanded enforced by `set_tool_state`.
- Testing: state machine, resume, mobile 390px, contrast (spec) → Tasks 2, 3, 4, 5.
- Rollout: no migration; tours + help; browser verify (spec) → Task 5.
- Future items (game groups, multi-window, per-account sync) → out of scope, untouched.

**Known v1 limitation (documented):** the Turn Timer countdown is in-memory in its client hook, so closing its panel resets the timer. Acceptable for v1; a localStorage-persisted timer is a follow-up.
