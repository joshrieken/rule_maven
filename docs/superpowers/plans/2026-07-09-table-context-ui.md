# Table-context strip + expansions tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the user's table setup (selected expansions + house-rule count) visible on every game screen and changeable from every game screen.

**Architecture:** A new `:expansions` tool holds the picker, extracted out of the Q&A sidebar. A new `SubBar.table_context/1` strip advertises the setup and taps into that tool (and the existing `:house_rules` tool). The desktop-only Rulebooks dropdown is deleted; its admin-only `↻ Regen` button relocates into the More menu. No migration, no schema change.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit.

## Global Constraints

- **Mobile-first.** Every UI change must be verified at 390px. The strip must never wrap: `flex-wrap:nowrap` in this exact bar has already once run pills off-screen, silently clipped by `main-content`'s `overflow-x`.
- **Contrast floors are test-enforced.** `--text-muted` on `--bg-subtle` is the pairing that fails. Fix the fill, not just the text.
- **Button system.** Use shared `btn-*` classes. No fresh inline button styles.
- **Tool convention.** A tool's `handle_event` clause must sit beside the host page's first `handle_event`, and tools are registered in `ToolRegistry` + given a `render_tool/1` clause in `ToolPanel`.
- **Tours upkeep.** User-facing feature changes must keep `/help` and tours correct.
- **No ids in URLs.** Opaque `RuleMaven.Hashid` tokens; `phx-value` ids stay raw.
- **Run only the tests relevant to the change.** Tee output to `./tmp/`, clean up after.

## Three collisions this plan must resolve

These are not in the spec. They were found while reading the code and each one silently breaks something:

1. **Tour target disappears.** `tours.ex:84` targets `[data-tour='expansions']`, which today sits on the always-visible picker at `show.ex:3738`. Moving that markup into a tool panel — closed by default — makes the step target a hidden element, which the tour **silently skips**. The attribute must move to the always-visible strip.
2. **Emoji collision.** `:first_player` already uses 🎲. The `:expansions` tool must not reuse it. Use 📦.
3. **Community crash.** `included_expansions` is woven through `show.ex` (ask at 964/992, `difficulty_weight` at 2612, `expansion_deltas` at 1990). `community.ex` has none of these assigns. A `toggle_expansion` handler promoted to `ToolHost` must not unconditionally recompute `expansion_deltas`.

---

## File Structure

- `lib/rule_maven_web/live/game_live/tool_registry.ex` — add `:expansions` descriptor.
- `lib/rule_maven_web/live/game_live/tool_panel.ex` — add `render_tool(%{tool: :expansions})`.
- `lib/rule_maven_web/live/game_live/tool_host.ex` — load expansion assigns + table context in `mount_header/2`; own `toggle_expansion`.
- `lib/rule_maven_web/live/game_live/show.ex` — delete picker markup + `toggle_expansion` handler; delegate.
- `lib/rule_maven_web/live/game_live/sub_bar.ex` — add `table_context/1`; delete `sources-dropdown`; relocate `↻ Regen`.
- `lib/rule_maven_web/tours.ex` — retarget the expansions step.
- Tests: `test/rule_maven_web/live/game_table_context_test.exs` (new), `test/rule_maven_web/live/game_expansions_tool_test.exs` (new), `test/rule_maven_web/live/game_subbar_parity_test.exs` (extend).

---

## Task 1: `:expansions` tool

The tool is the part that changes behaviour. It ships first, and is useful alone.

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/tool_registry.ex:22`
- Modify: `lib/rule_maven_web/live/game_live/tool_host.ex:54-63` (`mount_header/2`)
- Modify: `lib/rule_maven_web/live/game_live/tool_panel.ex` (new `render_tool/1` clause before the catch-all at :634)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:626-648` (move handler), `:3736-3755` (delete markup)
- Test: `test/rule_maven_web/live/game_expansions_tool_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Games.get_expansion_selection/2`, `RuleMaven.Games.put_expansion_selection/3` (both exist, `games.ex:333`/`:355`).
- Produces: assigns `:expansions` (list of `%Game{}`), `:included_expansions` (`%{expansion_id => true}`) on **every** game screen via `ToolHost.mount_header/2`. `ToolHost.handle_tool_event("toggle_expansion", …)`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven_web/live/game_expansions_tool_test.exs
defmodule RuleMavenWeb.GameExpansionsToolTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.AccountsFixtures
  import RuleMaven.GamesFixtures

  setup do
    user = user_fixture()
    base = game_fixture(%{name: "Wingspan", playable: true})
    exp = game_fixture(%{name: "Oceania", playable: true})
    # link_expansion/2 takes IDs, expansion first. games.ex:169
    RuleMaven.Games.link_expansion(exp.id, base.id)
    %{user: user, base: base, exp: exp}
  end

  test "toggling an expansion from the tool persists the selection",
       %{conn: conn, user: user, base: base, exp: exp} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")

    view |> element(~s|[phx-click="open_tool"][phx-value-id="expansions"]|) |> render_click()
    view |> element(~s|[phx-click="toggle_expansion"][phx-value-id="#{exp.id}"]|) |> render_click()

    assert RuleMaven.Games.get_expansion_selection(user.id, base.id) == [exp.id]
  end

  test "toggling from the community screen does not crash",
       %{conn: conn, user: user, base: base, exp: exp} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{base}/community")

    view |> element(~s|[phx-click="open_tool"][phx-value-id="expansions"]|) |> render_click()
    view |> element(~s|[phx-click="toggle_expansion"][phx-value-id="#{exp.id}"]|) |> render_click()

    assert RuleMaven.Games.get_expansion_selection(user.id, base.id) == [exp.id]
  end
end
```

> If `link_expansion/2` or the fixture names differ, read `test/support/fixtures/games_fixtures.ex` and `games_expansion_links_test.exs` and match what is there. Do not invent a fixture.

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p tmp && mix test test/rule_maven_web/live/game_expansions_tool_test.exs 2>&1 | tee tmp/t1.log`
Expected: FAIL — no element matching `phx-value-id="expansions"` (the tool does not exist).

- [ ] **Step 3: Register the tool**

`tool_registry.ex`, in the `:play` group, after `:timer`. **Not 🎲** — `:first_player` owns that.

```elixir
    %{id: :expansions, emoji: "📦", label: "Expansions", group: :play},
```

- [ ] **Step 4: Load expansion assigns for every game screen**

`tool_host.ex`, inside `mount_header/2`, appended to the `put_new` chain:

```elixir
    |> put_new(:expansions, fn _s -> RuleMaven.Games.expansions_for(game) end)
    |> put_new(:included_expansions, fn s ->
      case RuleMaven.Games.get_expansion_selection(s.assigns.current_user.id, game.id) do
        nil -> %{}
        ids -> Map.new(ids, &{&1, true})
      end
    end)
```

> `expansions_for/1` is at `games.ex:157`. **Do not invent `list_expansions/1` — it does not exist.**
>
> `show.ex:245-287` already builds both assigns in its connected mount. Read that block and reuse its exact logic rather than reimplementing: it distinguishes "row absent → default from the user's collection" from "`[]` → explicit base-only", per the `ExpansionSelection` moduledoc. Getting this wrong silently changes what expansions people play with. If `show.ex` already handles the `nil` case in a way the sketch above does not, `show.ex` is right and the sketch is wrong.

- [ ] **Step 5: Move the handler into ToolHost**

Cut `handle_event("toggle_expansion", …)` from `show.ex:626-648`. In `tool_host.ex`, add to `handle_tool_event/3`. Note the guard — this is collision #3:

```elixir
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

  # Only the Q&A screen carries `expansion_deltas`. Community has no such assign,
  # and recomputing it unconditionally would raise there.
  defp refresh_expansion_deltas(socket) do
    if Map.has_key?(socket.assigns, :expansion_deltas) do
      assign(socket,
        expansion_deltas:
          RuleMavenWeb.GameLive.Show.load_expansion_deltas(
            socket.assigns.expansions,
            socket.assigns.included_expansions
          )
      )
    else
      socket
    end
  end
```

> `load_expansion_deltas/2` is currently private in `show.ex` (see `:4414`). Make it public with a `@doc false`, or move it to `ToolHost` if `show.ex` is its only caller. Prefer moving it — `show.ex` is ~3000 LOC.

- [ ] **Step 6: Add the tool's `render_tool/1` clause**

`tool_panel.ex`, before the catch-all at `:634`. This is the markup lifted from `show.ex:3736-3755`, minus `data-tour` (which moves to the strip in Task 2):

```elixir
  defp render_tool(%{tool: :expansions} = assigns) do
    ~H"""
    <div :if={@expansions == []} style="font-size:0.8rem;color:var(--text-muted)">
      This game has no expansions.
    </div>
    <div :if={@expansions != []} style="display:flex;flex-wrap:wrap;gap:0.35rem">
      <label
        :for={exp <- @expansions}
        style={"cursor:pointer;font-size:0.72rem;padding:0.25rem 0.5rem;border-radius:0.3rem;#{if Map.get(@included_expansions, exp.id), do: "background:var(--accent);color:var(--accent-text,#fff)", else: "background:var(--bg-subtle);color:var(--text-muted);border:1px solid var(--border)"}"}
      >
        <input
          type="checkbox"
          checked={Map.get(@included_expansions, exp.id)}
          phx-click="toggle_expansion"
          phx-value-id={exp.id}
          style="display:none"
        />
        {exp.name}
      </label>
    </div>
    """
  end
```

- [ ] **Step 7: Delete the sidebar picker**

Remove `show.ex:3736-3755` (the `<%= if length(@expansions) > 0 do %>` block through its `<% end %>`). Leave the surrounding `max-width:48rem` wrapper intact.

- [ ] **Step 8: Run tests**

Run: `mix test test/rule_maven_web/live/game_expansions_tool_test.exs test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/t1.log`
Expected: PASS. If `game_live_difficulty_badge_test.exs` or the ask tests reference `included_expansions`, run those too — they read the assign this task moved.

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_expansions_tool_test.exs
git commit -m "feat(tools): expansion picker becomes a tool, reachable from every game screen"
```

---

## Task 2: `SubBar.table_context/1` strip

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (new component + call from `game_header_row`)
- Modify: `lib/rule_maven_web/live/game_live/tool_host.ex` (`house_rule_count` assign)
- Modify: `lib/rule_maven_web/tours.ex:84` (retarget)
- Test: `test/rule_maven_web/live/game_table_context_test.exs`

**Interfaces:**
- Consumes: `:expansions`, `:included_expansions` (Task 1), `RuleMaven.HouseRules.list_for_user/2` (`house_rules.ex:22`).
- Produces: `SubBar.table_context/1`; assign `:house_rule_count`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven_web/live/game_table_context_test.exs
defmodule RuleMavenWeb.GameTableContextTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.AccountsFixtures
  import RuleMaven.GamesFixtures

  setup do
    user = user_fixture()
    base = game_fixture(%{name: "Wingspan", playable: true})
    %{user: user, base: base}
  end

  test "base-game-only shows a muted base label", %{conn: conn, user: user, base: base} do
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")
    assert html =~ "Base game"
  end

  test "no house rules shows an Add affordance", %{conn: conn, user: user, base: base} do
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")
    assert html =~ ~s|data-testid="table-context-house-rules"|
    assert html =~ "Add"
  end

  test "selected expansions are named, extras collapse to +N",
       %{conn: conn, user: user, base: base} do
    for n <- ["Oceania", "European", "Asia"] do
      exp = game_fixture(%{name: n, playable: true})
      RuleMaven.Games.link_expansion(exp.id, base.id)
    end

    ids = base |> RuleMaven.Games.expansions_for() |> Enum.map(& &1.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, ids)

    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")
    assert html =~ "Oceania"
    assert html =~ "+2"
  end

  test "a game with no expansions hides the expansions half",
       %{conn: conn, user: user, base: base} do
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")
    refute html =~ ~s|data-testid="table-context-expansions"|
  end

  test "the expansions tour step targets a visible element",
       %{conn: conn, user: user, base: base} do
    exp = game_fixture(%{name: "Oceania", playable: true})
    RuleMaven.Games.link_expansion(exp.id, base.id)

    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{base}")
    assert html =~ ~s|data-tour="expansions"|
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_table_context_test.exs 2>&1 | tee tmp/t2.log`
Expected: FAIL — no `table-context-*` testids, no "Base game".

- [ ] **Step 3: Add the `house_rule_count` assign**

`tool_host.ex`, in the `mount_header/2` chain:

```elixir
    |> put_new(:house_rule_count, fn s ->
      length(RuleMaven.HouseRules.list_for_user(game.id, s.assigns.current_user.id))
    end)
```

Refresh it wherever `refresh_house_rules/1` (`show.ex:1436`) already runs.

- [ ] **Step 4: Write the component**

`sub_bar.ex`. Note `min-width:0` + ellipsis — this is the 390px clip regression guard.

```elixir
  attr :game, :map, required: true
  attr :expansions, :list, default: []
  attr :included_expansions, :map, default: %{}
  attr :house_rule_count, :integer, default: 0

  @doc """
  The table-context strip: what this user is actually playing with. Renders at
  all widths, directly under the game title.

  `data-tour="expansions"` lives here — not on the picker — because the picker
  now sits inside a tool panel that is closed by default, and a tour step
  pointed at a hidden element is silently skipped.
  """
  def table_context(assigns) do
    selected = Enum.filter(assigns.expansions, &Map.get(assigns.included_expansions, &1.id))
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <div class="table-context" style="display:flex;align-items:center;gap:0.6rem;flex-wrap:nowrap;min-width:0;font-size:0.68rem">
      <button
        :if={@expansions != []}
        type="button"
        data-tour="expansions"
        data-testid="table-context-expansions"
        phx-click="open_tool"
        phx-value-id="expansions"
        title={expansion_title(@selected)}
        aria-label={expansion_title(@selected)}
        class="pill-link"
        style="display:inline-flex;align-items:center;gap:0.25rem;min-width:0"
      >
        <span aria-hidden="true">📦</span>
        <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
          {expansion_label(@selected)}
        </span>
      </button>

      <button
        type="button"
        data-testid="table-context-house-rules"
        phx-click="open_tool"
        phx-value-id="house_rules"
        class="pill-link"
        style="display:inline-flex;align-items:center;gap:0.25rem;flex-shrink:0"
      >
        <span aria-hidden="true">🏠</span>
        <span>{if @house_rule_count == 0, do: "Add", else: @house_rule_count}</span>
      </button>
    </div>
    """
  end

  defp expansion_label([]), do: "Base game"
  defp expansion_label([one]), do: one.name
  defp expansion_label([first | rest]), do: "#{first.name} +#{length(rest)}"

  defp expansion_title([]), do: "Playing the base game — tap to add expansions"
  defp expansion_title(sel), do: "Playing with: " <> Enum.map_join(sel, ", ", & &1.name)
```

> `pill-link` is the sub-bar's own pill class, already used by the `<summary>` elements in `header_pills/1` and `more_menu/1`. There is **no `btn-ghost` class** in this codebase — the full set in `priv/static/assets/css/app.css` is: `btn-primary`, `btn-secondary`, `btn-outline`, `btn-danger`, `btn-danger-outline`, `btn-green`, `btn-icon`, `btn-sm`, `btn-xs`, `btn-add-source`, `btn-remove-source`. Do not invent a new one; `pill-link` is the right fit for a sub-bar pill.

- [ ] **Step 5: Render it from the header row**

`sub_bar.ex`, in `game_header_row`, inside `game-header-row__left`, after the `<.sub_bar …/>` call:

```elixir
        <.table_context
          game={@game}
          expansions={@expansions}
          included_expansions={@included_expansions}
          house_rule_count={@house_rule_count}
        />
```

Thread the three new attrs through `game_bar/1` and `game_header_row/1` (`attr` declarations at `:25-32` and `:59-69`).

- [ ] **Step 6: Retarget the tour**

`tours.ex:84`. The selector is unchanged (`[data-tour='expansions']`) but now resolves to the strip. Update the step copy to match, since it no longer points at a checkbox row:

```elixir
        sel: "[data-tour='expansions']",
        title: "Playing with expansions?",
        body: "This shows what you're playing with. Tap it to add or remove expansions — answers adjust to match.",
```

- [ ] **Step 7: Run tests**

Run: `mix test test/rule_maven_web/live/game_table_context_test.exs test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/t2.log`
Expected: PASS.

- [ ] **Step 8: Verify at 390px**

Run the app, open a game with 3+ selected expansions at 390px width. Confirm the strip does not wrap and its right edge stays inside the viewport. This is the exact regression that has happened before in this bar.

Also confirm the muted variants clear the contrast floor:

```
mix test test/rule_maven_web/static_theme_accent_text_test.exs test/rule_maven/theme_palette_test.exs
```

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/ test/rule_maven_web/live/game_table_context_test.exs
git commit -m "feat(subbar): table-context strip shows expansions + house rules on every game screen"
```

---

## Task 3: Delete the Rulebooks dropdown, relocate `↻ Regen`

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex:141-180` (delete `<details class="sources-dropdown">`), `:283-334` (More menu gains Regen)
- Test: `test/rule_maven_web/live/game_subbar_parity_test.exs` (extend)

**Interfaces:**
- Consumes: `sources` list (`ToolHost.mount_header/2` already assigns it), `regenerate_html` handler (exists in `show.ex` only).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

```elixir
  # append to test/rule_maven_web/live/game_subbar_parity_test.exs

  test "the desktop Rulebooks dropdown is gone", %{conn: conn, user: user, game: game} do
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{game}")
    refute html =~ "sources-dropdown"
  end

  test "admins can still regenerate HTML from the More menu on the game page",
       %{conn: conn, game: game} do
    admin = user_fixture(%{role: "admin"})
    {:ok, _view, html} = conn |> log_in_user(admin) |> live(~p"/games/#{game}")
    assert html =~ ~s|phx-click="regenerate_html"|
  end

  test "regenerate_html is absent for non-admins", %{conn: conn, user: user, game: game} do
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/games/#{game}")
    refute html =~ ~s|phx-click="regenerate_html"|
  end

  test "regenerate_html is absent off the game page", %{conn: conn, game: game} do
    admin = user_fixture(%{role: "admin"})
    {:ok, _view, html} = conn |> log_in_user(admin) |> live(~p"/games/#{game}/community")
    refute html =~ ~s|phx-click="regenerate_html"|
  end
```

> The admin fixture must produce a user for whom `RuleMaven.Users.can?(user, :admin)` is true. Check `accounts_fixtures.ex` and the `authorization-capabilities` pattern — gate on capability, not a role string. The game fixture needs at least one source with an `html_path` for the Regen button to render.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/t3.log`
Expected: FAIL — `"sources-dropdown"` is still present.

- [ ] **Step 3: Delete the dropdown**

`sub_bar.ex`: remove the entire `<details :if={@sources != []} class="sources-dropdown hide-mobile">` block from `header_pills/1` (`:141` through its closing `</details>`). Then remove `attr :sources` from `header_pills/1` (`:129`) and drop `sources={@sources}` from its call site (`:117`).

`game_bar/1` and `game_header_row/1` keep their `sources` attrs — the More menu still needs them.

- [ ] **Step 4: Relocate `↻ Regen` into the More menu**

`sub_bar.ex`, in `more_menu/1`, inside the `for src <- @sources` loop. Replace the admin branch:

```elixir
          <%= for src <- @sources do %>
            <%= if @is_admin and src.html_path do %>
              <div class="card-menu__item" style="display:flex;align-items:center;gap:0.5rem">
                <.link href={~p"/rulebooks/#{src}/html"} target="_blank" style="flex:1;min-width:0">
                  {src.label}
                </.link>
                <%!-- `regenerate_html` is handled only on the game page. --%>
                <button
                  :if={@current == :show}
                  type="button"
                  phx-click="regenerate_html"
                  phx-value-id={src.id}
                  title="Re-render the HTML view from the current text"
                  class="btn-xs"
                >↻</button>
              </div>
            <% else %>
              <div class="card-menu__item" style="cursor:default">{src.label}</div>
            <% end %>
          <% end %>
```

- [ ] **Step 5: Run tests**

Run: `mix test test/rule_maven_web/live/game_subbar_parity_test.exs test/rule_maven_web/feature/subbar_visual_test.exs 2>&1 | tee tmp/t3.log`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/sub_bar.ex test/rule_maven_web/live/game_subbar_parity_test.exs
git commit -m "refactor(subbar): drop the duplicate Rulebooks dropdown, keep Regen in the More menu"
```

---

## Task 4: Help page + verification

**Files:**
- Modify: the `/help` template (find it: `grep -rl "help" lib/rule_maven_web/controllers lib/rule_maven_web/live | head`)

- [ ] **Step 1: Document the strip and the expansions tool on `/help`**

Per the standing rule, new user-facing features update `/help`. One short entry: what the strip shows, that tapping it changes your setup, and that answers adjust to the expansions you select.

- [ ] **Step 2: Drive the app**

Start the server. On a real game with three house rules and two expansions:

1. Confirm the strip renders under the title on `/games/:id`, `/games/:id/community`, `/games/:id/prepare`.
2. Toggle an expansion from the tool on Community. Confirm no crash and the strip updates. (This is collision #3.)
3. Confirm the expansions tour step highlights the strip rather than skipping.
4. **Confirm the house-rule overlay attaches the right house rule to the right answer.** The strip advertises that house rules modify answers; that claim is verified as code-with-tests but has never been observed in a browser. If the embedding match is poor, the strip is still correct — but say so rather than shipping the pitch quietly.

Kill the server when done. Never leave a worktree `mix phx.server` running — it drains the shared dev Oban queue.

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven_web/
git commit -m "docs(help): document the table-context strip and expansions tool"
```

---

## Self-review notes

- Spec coverage: strip (Task 2), expansions tool (Task 1), dropdown removal + Regen relocation (Task 3), edge cases (Task 2 Step 1 tests), 390px + contrast (Task 2 Step 8), browser verification (Task 4 Step 2). The spec's "no migration" holds — no task touches `priv/repo/migrations`.
- Three collisions found in code but absent from the spec are called out at the top and each has a task step.
- Function names used across tasks: `table_context/1`, `expansion_label/1`, `expansion_title/1`, `refresh_expansion_deltas/1`, `load_expansion_deltas/2`. Consistent throughout.
- All function and class names in this plan were verified against the source:
  `Games.expansions_for/1` (`games.ex:157`), `Games.link_expansion/2` — **ids,
  expansion first** (`games.ex:169`), `Games.get_expansion_selection/2`
  (`:355`), `Games.put_expansion_selection/3` (`:333`),
  `HouseRules.list_for_user/2` (`house_rules.ex:22`), `pill-link` (the sub-bar's
  own pill class). The first draft of this plan had `list_expansions/1`,
  `link_expansion(base, exp)`, and `btn-ghost-xs` — none of which exist.
- One thing the implementer must still read rather than trust: the `nil` vs `[]`
  branch of `get_expansion_selection/2`, whose correct handling lives in
  `show.ex:245-287`. Copying the sketch in Task 1 Step 4 without reading that
  block risks silently changing which expansions a user plays with.
