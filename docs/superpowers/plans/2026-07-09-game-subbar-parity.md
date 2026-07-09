# Game Sub-Bar Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the game sub-bar render identically — same chrome, same right-side pills, pinned to the top — on all five user-facing game LiveViews.

**Architecture:** The `SubBar` component already renders on every page; only its surroundings differ. Move the chrome into a new `game_bar/1` wrapper, move Show's right-side pills into the component behind a new `current` attr, and pin the wrapper with `position: sticky` against `.main-content`. Pages then hoist `game_bar` out of their centered column so it goes full-bleed.

**Tech Stack:** Elixir, Phoenix LiveView (function components, `~H` sigil), plain CSS in `priv/static/assets/css/app.css`, ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-game-subbar-parity-design.md`. Read it before starting.
- **Mobile-first.** Every UI change is verified at 390px. The pills carry `hide-mobile`; at 390px the bar's right side is empty on every page.
- **Contrast floors** are enforced by tests. The bar's background must be opaque (`var(--bg-surface)`), never a translucent overlay on the game art.
- **Buttons** use the shared `btn-*` classes. Never write fresh inline button styles.
- **No ids in URLs.** Routes take `~p"/games/#{@game}"`, which uses the game's Hashid token. `phx-value-*` attributes keep raw ids.
- Run only the tests relevant to the change. Tee output to `./tmp/<name>.log`; do not run the suite twice.
- `current` is one of exactly: `:show`, `:community`, `:prepare`, `:review`, `:edit`.
- Commit after each task. Do not push.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/rule_maven_web/live/game_live/sub_bar.ex` | The bar: chrome wrapper, header row, group menus, pills | Modify — add `game_bar/1`, `header_pills/1`; swap `on_game_page` → `current` |
| `lib/rule_maven_web/live/game_live/tool_host.ex` | Shared mount-time assigns for game pages | Modify — `mount_header/2` gains `:has_cheatsheet` |
| `lib/rule_maven_web/live/game_live/show.ex` | Q&A page | Modify — assign `has_cheatsheet`; slot reduced to `☰`; `.game-bar` class |
| `lib/rule_maven_web/live/game_live/community.ex` | Community Q&A page | Modify — call `mount_header/2`; hoist `game_bar` |
| `lib/rule_maven_web/live/game_live/prepare.ex` | Prepare page | Modify — hoist `game_bar` |
| `lib/rule_maven_web/live/game_live/review.ex` | Review page | Modify — hoist `game_bar` |
| `lib/rule_maven_web/live/game_live/form.ex` | Edit / Add Game form | Modify — hoist `game_bar` behind `:if={@game}` |
| `priv/static/assets/css/app.css` | Styles | Modify — add `.game-bar`, fold in `.chat-header .game-header-row` |
| `test/rule_maven_web/live/game_subbar_parity_test.exs` | Parity tests | Create |

---

### Task 1: Replace `on_game_page` with `current`

The boolean encodes "am I on the Show page", which `current` says outright. The
pills in later tasks need to know *which* page they are on, not merely whether
it is Show, so the boolean has to go first. Pure refactor — no visual change.

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (attrs at :19, :78, :143; body at :40, :51, :66, :100, :159, :162)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:2295` (call site)
- Modify: `lib/rule_maven_web/live/game_live/community.ex:407`
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex:691`
- Modify: `lib/rule_maven_web/live/game_live/review.ex:81`
- Modify: `lib/rule_maven_web/live/game_live/form.ex:2600`
- Test: `test/rule_maven_web/live/game_subbar_parity_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `SubBar.game_header/1` accepts `current: :show | :community | :prepare | :review | :edit` and no longer accepts `on_game_page`. Private `SubBar.sub_bar/1` and `SubBar.more_menu/1` take `current` too.

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/game_subbar_parity_test.exs`:

```elixir
defmodule RuleMavenWeb.GameSubBarParityTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  setup %{conn: conn} do
    game = published_game_fixture()
    admin = create_user("subbar_admin", %{role: "admin"})
    %{conn: login(conn, admin), game: game, admin: admin}
  end

  test "the game page patches to the overview; other pages navigate", %{conn: conn, game: game} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    # A patch link carries data-phx-link="patch"; a navigate link, "redirect".
    assert show_html =~ ~s(data-phx-link="patch")

    {:ok, _view, community_html} = live(conn, ~p"/games/#{game}/community")
    refute community_html =~ ~s(data-phx-link="patch")
    assert community_html =~ ~s(data-phx-link="redirect")
  end
end
```

- [ ] **Step 2: Run the test to verify it passes against the current code**

```bash
mkdir -p tmp
mix test test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/subbar-t1.log
```

Expected: PASS. This test is a **characterisation test** — it pins the
patch/navigate behaviour that `on_game_page` provides today, so that swapping it
for `current` cannot silently regress it. If it fails, stop: the bar is already
broken and this plan's premise is wrong.

- [ ] **Step 3: Swap the attr in `sub_bar.ex`**

Replace the `on_game_page` attr on `game_header/1` (line 19) with:

```elixir
  # Which page the bar is being rendered on. Drives two things: the Overview
  # link patches on :show and navigates elsewhere (patching across LiveViews
  # crashes), and a pill pointing at the current page renders inert.
  attr :current, :atom, default: :show, values: [:show, :community, :prepare, :review, :edit]
```

In `game_header/1`'s body, replace `:if={@on_game_page}` with `:if={@current == :show}`
(line 40), `:if={!@on_game_page}` with `:if={@current != :show}` (line 51), and
pass `current={@current}` to `<.sub_bar>` instead of `on_game_page={@on_game_page}`
(line 66).

Apply the same attr swap to `sub_bar/1` (line 78 → `attr :current, :atom, default: :show`)
and `more_menu/1` (line 143 → `attr :current, :atom, required: true`), passing
`current={@current}` down at line 100.

In `more_menu/1`, replace `:if={@on_game_page}` with `:if={@current == :show}` (line 159)
and `:if={!@on_game_page}` with `:if={@current != :show}` (line 162).

- [ ] **Step 4: Update the five call sites**

`show.ex:2295` — the call currently passes no `on_game_page` (it defaulted to
`true`). Add the explicit value:

```heex
        <SubBar.game_header
          game={@game}
          sources={@sources}
          community_count={@community_count}
          is_admin={@is_admin}
          current={:show}
        >
```

In `community.ex:407`, `prepare.ex:691`, `review.ex:81` and `form.ex:2600`,
replace the `on_game_page={false}` line with `current={:community}`,
`current={:prepare}`, `current={:review}` and `current={:edit}` respectively.

- [ ] **Step 5: Run the tests to verify they still pass**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs test/rule_maven_web/live/community_live_test.exs 2>&1 | tee tmp/subbar-t1.log
```

Expected: PASS. `mix compile --warnings-as-errors` must also be clean — a
leftover `on_game_page={...}` at any call site raises an "undefined attribute"
compile warning, which is how you know you caught all five.

```bash
mix compile --force --warnings-as-errors 2>&1 | tee -a tmp/subbar-t1.log
```

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_subbar_parity_test.exs
git commit -m "refactor(subbar): name the page the bar is on, not whether it is Show"
```

---

### Task 2: Hoist the Cheat Sheet check to a `has_cheatsheet` assign

`Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil))` is one query
per source on **every render**. It runs twice on Show today (More menu + pill).
Task 3 puts the pill on five pages, so this must become a mount-time assign
first, or the query count multiplies.

Note that Show assigns `sources` in `handle_params`, not `mount` — its game is
`nil` at mount. So Show computes the assign where it loads its sources, and the
other four get it from `ToolHost.mount_header/2`.

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/tool_host.ex:54-64`
- Modify: `lib/rule_maven_web/live/game_live/show.ex:283` (the `load_game` assign block)
- Modify: `lib/rule_maven_web/live/game_live/community.ex:37` (`mount_game`)
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (`more_menu/1` reads the assign)
- Test: `test/rule_maven_web/live/game_subbar_parity_test.exs`

**Interfaces:**
- Consumes: `current` from Task 1.
- Produces:
  - `ToolHost.has_cheatsheet?(sources :: [%RuleMaven.Games.Document{}]) :: boolean()`
  - `ToolHost.mount_header/2` now also assigns `:has_cheatsheet`.
  - `SubBar.game_header/1`, `sub_bar/1` and `more_menu/1` accept `attr :has_cheatsheet, :boolean, default: false`.

- [ ] **Step 1: Write the failing test**

Append to `test/rule_maven_web/live/game_subbar_parity_test.exs`:

```elixir
  test "has_cheatsheet?/1 is true only when some source has an active version" do
    alias RuleMavenWeb.GameLive.ToolHost

    refute ToolHost.has_cheatsheet?([])
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/subbar-t2.log
```

Expected: FAIL with `function RuleMavenWeb.GameLive.ToolHost.has_cheatsheet?/1 is undefined or private`.

- [ ] **Step 3: Add the helper and the assign**

In `tool_host.ex`, add above `mount_header/2`:

```elixir
  @doc """
  Whether any of the game's sources has an active cheat-sheet version.

  One query per source, so it is computed once at mount and passed down as an
  assign — the sub-bar renders on every game page and would otherwise re-run it
  on each render, once for the More menu and once for the pill.
  """
  def has_cheatsheet?(sources) do
    Enum.any?(sources, &(RuleMaven.CheatSheet.active_version(&1.id) != nil))
  end
```

Then extend `mount_header/2`. `:sources` must be resolved before `:has_cheatsheet`
reads it, so append the new `put_new` last:

```elixir
  def mount_header(socket, game) do
    socket
    |> put_new(:coarse_pointer, fn ->
      connected?(socket) and get_connect_params(socket)["coarse_pointer"] == true
    end)
    |> put_new(:is_admin, fn -> RuleMaven.Users.can?(socket.assigns.current_user, :admin) end)
    |> put_new(:sources, fn -> RuleMaven.Games.list_documents(game) end)
    |> put_new(:community_count, fn -> RuleMaven.Faq.community_count(game) end)
    |> put_new(:has_cheatsheet, fn -> has_cheatsheet?(socket.assigns.sources) end)
  end
```

Careful: `put_new/3` reads `socket.assigns.sources` from the socket it was
*given*, not the piped one. Change `put_new/3` to pass the accumulated socket
into the function:

```elixir
  defp put_new(socket, key, fun) do
    if Map.has_key?(socket.assigns, key), do: socket, else: assign(socket, key, fun.(socket))
  end
```

and make every callback take the socket:

```elixir
    |> put_new(:coarse_pointer, fn s ->
      connected?(s) and get_connect_params(s)["coarse_pointer"] == true
    end)
    |> put_new(:is_admin, fn s -> RuleMaven.Users.can?(s.assigns.current_user, :admin) end)
    |> put_new(:sources, fn _s -> RuleMaven.Games.list_documents(game) end)
    |> put_new(:community_count, fn _s -> RuleMaven.Faq.community_count(game) end)
    |> put_new(:has_cheatsheet, fn s -> has_cheatsheet?(s.assigns.sources) end)
```

- [ ] **Step 4: Assign it on the two pages that skip `mount_header/2`**

In `show.ex`, inside the `assign(socket, ...)` block at line ~283, next to
`sources: sources,` add:

```elixir
        has_cheatsheet: ToolHost.has_cheatsheet?(sources),
```

In `community.ex`'s `mount_game/2`, replace the hand-rolled header assigns with a
`mount_header/2` call. Delete `is_admin:`, `sources:`, `community_count:` and
`coarse_pointer:` from its `assign(socket, ...)` block, keep the rest, and after
that block insert — before the existing `ToolHost.mount_tools(socket, game)`:

```elixir
    socket = ToolHost.mount_header(socket, game)
```

`community.ex` reads `socket.assigns.is_admin` later in `load_questions/1` and in
event handlers; `mount_header/2` assigns it before `mount_tools/2` runs, so those
reads still find it.

- [ ] **Step 5: Thread the assign through the component**

In `sub_bar.ex`, add to the attr lists of `game_header/1`, `sub_bar/1` and
`more_menu/1`:

```elixir
  attr :has_cheatsheet, :boolean, default: false
```

(on `more_menu/1` make it `required: true`), pass `has_cheatsheet={@has_cheatsheet}`
down through both call sites, and replace the More menu's inline query at line 170:

```heex
        <%= if @has_cheatsheet do %>
          <.link href={~p"/games/#{@game}/cheatsheet"} target="_blank" class="card-menu__item">
            📋 Cheat Sheet
          </.link>
        <% end %>
```

Delete the now-unused `alias RuleMaven.CheatSheet` at `sub_bar.ex:10` if nothing
else in the file references it.

Add `has_cheatsheet={@has_cheatsheet}` to all five `game_header` call sites.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs test/rule_maven_web/live/community_live_test.exs 2>&1 | tee tmp/subbar-t2.log
mix compile --force --warnings-as-errors 2>&1 | tee -a tmp/subbar-t2.log
```

Expected: PASS, no warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_subbar_parity_test.exs
git commit -m "perf(subbar): compute the cheat-sheet check once at mount"
```

---

### Task 3: Move the right-side pills into the component

The pills live in Show's `inner_block` slot today. Move them into `SubBar` so
every page paints them from one source. Two hazards, both from the spec:

- `↻ Regen` is wired to `phx-click="regenerate_html"`, a handler defined **only
  in `show.ex`**. On any other page an admin clicking it crashes the LiveView.
  Gate it to `current == :show`.
- The Community pill on the Community page must render inert, not as a link to
  itself.

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex`
- Modify: `lib/rule_maven_web/live/game_live/show.ex:2295-2372` (slot shrinks to `☰`)
- Test: `test/rule_maven_web/live/game_subbar_parity_test.exs`

**Interfaces:**
- Consumes: `current` (Task 1), `has_cheatsheet` (Task 2).
- Produces: private `SubBar.header_pills/1`, rendered inside `game_header/1`'s
  `.game-header-row__right` region before any slot content.

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven_web/live/game_subbar_parity_test.exs`:

```elixir
  test "every game page renders the Community pill", %{conn: conn, game: game} do
    # The pill only appears once the game has a community question to point at.
    {:ok, _q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        visibility: "public"
      })

    for path <- [
          ~p"/games/#{game}",
          ~p"/games/#{game}/community",
          ~p"/games/#{game}/review",
          ~p"/games/#{game}/edit"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Community Q&amp;A", "no Community pill on #{path}"
    end
  end

  test "the Community pill is inert on the Community page", %{conn: conn, game: game} do
    {:ok, _q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        visibility: "public"
      })

    {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")
    assert html =~ ~s(aria-current="page")

    # The inert pill must not also be a link to the page you are already on.
    refute html =~ ~s(href="/games/#{RuleMaven.Hashid.encode(game.id)}/community")
  end

  test "the admin Regen button renders only on the game page", %{conn: conn, game: game} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    {:ok, _view, review_html} = live(conn, ~p"/games/#{game}/review")

    # Both are rendered for an admin, so a difference here is the gate working,
    # not an authorization accident.
    assert show_html =~ "regenerate_html" or show_html =~ "Rulebooks"
    refute review_html =~ "regenerate_html"
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/subbar-t3.log
```

Expected: FAIL — "no Community pill on /games/…/review", and no `aria-current`.

- [ ] **Step 3: Add `header_pills/1` to `sub_bar.ex`**

Add this private component below `game_header/1`:

```elixir
  attr :game, :map, required: true
  attr :sources, :list, required: true
  attr :community_count, :integer, required: true
  attr :is_admin, :boolean, required: true
  attr :has_cheatsheet, :boolean, required: true
  attr :current, :atom, required: true

  # The right-hand shortcuts. Every destination here is also a More-menu item —
  # deliberately: these are `hide-mobile` desktop shortcuts and the More menu is
  # the mobile path to the same places. A pill pointing at the current page
  # renders inert rather than vanishing, so the bar keeps its shape between pages.
  defp header_pills(assigns) do
    ~H"""
    <details
      :if={@sources != []}
      class="sources-dropdown hide-mobile"
      style="flex-shrink:0;position:relative;display:inline-flex;align-items:center"
    >
      <summary class="pill-link" style="cursor:pointer;list-style:none;gap:0.2rem;user-select:none">
        <span aria-hidden="true">📖</span>
        <span>Rulebooks</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div style="position:absolute;right:0;top:calc(100% + 0.35rem);z-index:200;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;box-shadow:0 6px 20px rgba(0,0,0,0.18);min-width:200px;max-width:min(320px,calc(100vw - 2rem));overflow:hidden">
        <%= for {src, i} <- Enum.with_index(@sources) do %>
          <div style={"padding:0.5rem 0.75rem;#{if i > 0, do: "border-top:1px solid var(--border-subtle)"}"}>
            <div style="font-size:0.78rem;font-weight:600;color:var(--text);margin-bottom:0.25rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
              {src.label}
            </div>
            <%!-- Rulebooks may be copyrighted, so regular users see only the
                  source name — no PDF, no full text. Admins get the extracted
                  HTML view. `↻ Regen` posts `regenerate_html`, a handler that
                  exists only on the game page, so it is gated to :show. --%>
            <div :if={@is_admin and src.html_path} style="display:flex;gap:0.5rem">
              <.link
                href={~p"/rulebooks/#{src}/html"}
                target="_blank"
                style="display:inline-flex;align-items:center;gap:0.2rem;color:var(--blue);font-size:0.7rem;font-weight:600;text-decoration:none;padding:0.15rem 0.4rem;border:1px solid var(--blue);border-radius:0.25rem;opacity:0.85"
              >🔗 HTML</.link>
              <button
                :if={@current == :show}
                type="button"
                phx-click="regenerate_html"
                phx-value-id={src.id}
                title="Re-render the HTML view from the current text"
                class="btn-xs"
              >↻ Regen</button>
            </div>
          </div>
        <% end %>
      </div>
    </details>

    <.pill_link
      :if={@community_count > 0}
      navigate={~p"/games/#{@game}/community"}
      current={@current == :community}
      class="btn btn-primary btn-xs hide-mobile"
    >
      <span aria-hidden="true">💬</span> Community Q&amp;A ({@community_count})
    </.pill_link>

    <%!-- The cheat sheet is a standalone printable document, never "the current
          page", so it is always a plain link. --%>
    <.link
      :if={@has_cheatsheet}
      href={~p"/games/#{@game}/cheatsheet"}
      target="_blank"
      class="btn btn-xs hide-mobile"
      style="flex-shrink:0"
    >
      Cheat Sheet
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :current, :boolean, required: true
  attr :class, :string, required: true
  slot :inner_block, required: true

  # A pill that points at the page you are already on renders inert rather than
  # linking to itself — but it keeps its place, so the bar's shape never shifts
  # between pages. Label and count live here once; only the element changes.
  defp pill_link(assigns) do
    ~H"""
    <span :if={@current} class={@class} aria-current="page" style="flex-shrink:0">
      {render_slot(@inner_block)}
    </span>
    <.link :if={!@current} navigate={@navigate} class={@class} style="flex-shrink:0">
      {render_slot(@inner_block)}
    </.link>
    """
  end
```

- [ ] **Step 4: Render the pills from `game_header/1`**

The right region must render whenever there are pills, even with an empty slot.
Replace line 69 of `sub_bar.ex`:

```heex
      <div class="game-header-row__right">
        {render_slot(@inner_block)}
        <.header_pills
          game={@game}
          sources={@sources}
          community_count={@community_count}
          is_admin={@is_admin}
          has_cheatsheet={@has_cheatsheet}
          current={@current}
        />
      </div>
```

Slot content comes first so Show's `☰` stays the leftmost control of the group,
as its original comment required.

- [ ] **Step 5: Shrink Show's slot to the sidebar toggle**

In `show.ex`, the `<SubBar.game_header>` block spans roughly lines 2295-2372.
Delete everything between the `☰` button and `</SubBar.game_header>` — the
`sources-dropdown` details element, the Community Q&A link, and the Cheat Sheet
link. The slot becomes:

```heex
        <SubBar.game_header
          game={@game}
          sources={@sources}
          community_count={@community_count}
          is_admin={@is_admin}
          has_cheatsheet={@has_cheatsheet}
          current={:show}
        >
          <%!-- Sidebar toggle: kept first so it is the leftmost control on
                whichever row this group wraps onto on narrow screens. The
                Rulebooks / Community / Cheat Sheet pills now live in the shared
                bar, so every game screen paints them identically. --%>
          <button
            type="button"
            phx-click="toggle_sidebar"
            class="sidebar-toggle btn-icon btn-sm"
          >☰</button>
        </SubBar.game_header>
```

If `show.ex` no longer references `CheatSheet`, delete its alias.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs test/rule_maven_web/live/community_live_test.exs 2>&1 | tee tmp/subbar-t3.log
mix compile --force --warnings-as-errors 2>&1 | tee -a tmp/subbar-t3.log
```

Expected: PASS, no warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_subbar_parity_test.exs
git commit -m "feat(subbar): give every game page the same right-side pills"
```

---

### Task 4: Add the `game_bar` chrome and pin it

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (add `game_bar/1`)
- Modify: `priv/static/assets/css/app.css:2803-2819`
- Modify: `lib/rule_maven_web/live/game_live/show.ex:2291` (the `.chat-header` div)
- Modify: `lib/rule_maven_web/live/game_live/community.ex:404-413`
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex:690-698`
- Modify: `lib/rule_maven_web/live/game_live/review.ex:80-88`
- Modify: `lib/rule_maven_web/live/game_live/form.ex:2563, 2600-2608`

**Interfaces:**
- Consumes: `game_header/1` with `current` + `has_cheatsheet` (Tasks 1-3).
- Produces: `SubBar.game_bar/1` — same attrs as `game_header/1`, plus a
  passthrough `inner_block` slot. Pages call `game_bar`; `game_header` becomes
  its implementation detail.

- [ ] **Step 1: Write the failing test**

Append to `test/rule_maven_web/live/game_subbar_parity_test.exs`:

```elixir
  test "every game page wraps the bar in the same chrome", %{conn: conn, game: game} do
    for path <- [
          ~p"/games/#{game}",
          ~p"/games/#{game}/community",
          ~p"/games/#{game}/review",
          ~p"/games/#{game}/edit"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "game-bar", "no .game-bar chrome on #{path}"
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs 2>&1 | tee tmp/subbar-t4.log
```

Expected: FAIL with "no .game-bar chrome on /games/…".

- [ ] **Step 3: Add `game_bar/1` to `sub_bar.ex`**

Above `game_header/1`:

```elixir
  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :has_cheatsheet, :boolean, default: false
  attr :current, :atom, default: :show, values: [:show, :community, :prepare, :review, :edit]
  attr :class, :string, default: nil, doc: "extra classes for the chrome element"
  slot :inner_block

  @doc """
  The bar as every game screen wears it: full-bleed chrome, pinned to the top of
  the scroll container, wrapping the header row. Pages render this, not
  `game_header/1` — the chrome is what makes the bar the same control everywhere.

  Render it as a sibling *before* the page's centered content column, so it
  spans the viewport while the content stays centered.
  """
  def game_bar(assigns) do
    ~H"""
    <div class={["game-bar", @class]}>
      <.game_header
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        has_cheatsheet={@has_cheatsheet}
        current={@current}
      >
        {render_slot(@inner_block)}
      </.game_header>
    </div>
    """
  end
```

`game_header/1`'s `@inner_block != []` guard is gone as of Task 3, so an empty
slot renders nothing. Good.

- [ ] **Step 4: Add the CSS**

In `app.css`, replace lines 2803-2811 (`.game-header-row` through
`.chat-header .game-header-row`) with:

```css
.game-header-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.35rem;
  flex-wrap: wrap;
}

/* The chrome every game screen wears. Sticky, not fixed: it pins to the top of
   .main-content (the real scroll container) so the tools stay one tap away no
   matter how far down the page you have scrolled. The background must be opaque
   — the blurred game art sits behind it and would otherwise scroll through. */
.game-bar {
  position: sticky;
  top: 0;
  z-index: 20;
  padding: 0.25rem 0.75rem;
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
}

/* Sticky is measured from .main-content's PADDING box, so leaving its top
   padding in place would strand the bar in a blank band below the header. Same
   fix `.main-content:has(.game-list)` applies for .list-controls. */
.main-content:has(.game-bar) {
  padding-top: 0;
}
```

Note `margin-bottom: 1rem` is dropped from `.game-header-row` — the chrome's own
padding now provides the separation, and the old `.chat-header .game-header-row
{ margin-bottom: 0 }` override that existed only to cancel it is deleted.

- [ ] **Step 5: Convert Show's header div**

`show.ex:2291`. The `.chat-header` div's inline styles duplicate what `.game-bar`
now provides. Replace:

```heex
      <div
        class="chat-header"
        style="flex-shrink:0;padding:0.25rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface);position:relative;z-index:20"
      >
        <SubBar.game_header … >
```

with a `game_bar` carrying the `chat-header` class for the chat layout's own
rules (`.chat-layout .chat-header` has a reduced-motion rule at app.css:850):

```heex
      <SubBar.game_bar
        class="chat-header"
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        has_cheatsheet={@has_cheatsheet}
        current={:show}
      >
        <button type="button" phx-click="toggle_sidebar" class="sidebar-toggle btn-icon btn-sm">☰</button>
      </SubBar.game_bar>
```

and delete the now-orphaned closing `</div>`. Add to `app.css` beside `.game-bar`:

```css
/* Inside the fixed chat shell the bar does not scroll, so sticky is inert —
   but the flex column still needs it to hold its height. */
.chat-layout .game-bar { flex-shrink: 0; }
```

- [ ] **Step 6: Hoist the bar on the other four pages**

In each of `community.ex`, `prepare.ex` and `review.ex`, move the
`<SubBar.game_header …/>` element out of the centered column and turn it into a
`<SubBar.game_bar …/>` placed directly after `<GameTheme.blur_background …/>`.
For `community.ex` the render becomes:

```heex
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game.image_url} />
    <ReportModal.report_modal :if={@report_target} />
    <SubBar.game_bar
      game={@game}
      sources={@sources}
      community_count={@community_count}
      is_admin={@is_admin}
      has_cheatsheet={@has_cheatsheet}
      current={:community}
    />
    <div style="max-width:52rem;margin:0 auto;padding:1.5rem 1rem;position:relative;z-index:1">
      <h1 style="font-size:1.25rem;font-weight:700;margin-bottom:0.25rem">
```

`prepare.ex` and `review.ex` are the same shape — bar after `blur_background`,
before their `max-width` div — with `current={:prepare}` and `current={:review}`.
Keep each page's existing column `style` untouched.

`form.ex` has no centered column; its wrapper is `<div class="game-form" …>` at
line 2563. Move the bar above that div, keeping its guard:

```heex
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game && @game.image_url} />
    <SubBar.game_bar
      :if={@game}
      game={@game}
      sources={@sources}
      community_count={@community_count}
      is_admin={@is_admin}
      has_cheatsheet={@has_cheatsheet}
      current={:edit}
    />
    <div class="game-form" style="position:relative;z-index:1">
```

and delete the old `<SubBar.game_header :if={@game} …/>` at line 2600. The
"Add Game" plain row at `form.ex:2604` (`<div :if={!@game} …>`) stays where it is.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
mix test test/rule_maven_web/live/game_subbar_parity_test.exs test/rule_maven_web/live/community_live_test.exs test/rule_maven_web/live/game_live_landing_overview_test.exs 2>&1 | tee tmp/subbar-t4.log
mix compile --force --warnings-as-errors 2>&1 | tee -a tmp/subbar-t4.log
```

Expected: PASS, no warnings.

- [ ] **Step 8: Verify at 390px**

This is a major visual change, so verify it in the browser per the mobile-first
rule. Start the server (from the worktree; kill it afterwards — an orphaned
worktree server drains the shared dev Oban queue):

```bash
mix phx.server
```

At a 390px viewport, on each of `/games/:id`, `/games/:id/community`,
`/games/:id/prepare`, `/games/:id/review`, `/games/:id/edit`, confirm:

1. The bar spans the full viewport width with an opaque background.
2. `← Catan 🎲Play ▾ 📚Learn ▾ 💬More ▾` fits on one row without clipping — the
   pills are `hide-mobile` and must not appear.
3. Scrolling the page leaves the bar pinned, with no blank band above it and no
   game art showing through.
4. No horizontal scrollbar appears. `.game-header-row` is `flex-wrap: wrap`; if
   a row runs off-screen it will be silently clipped by `main-content`'s
   `overflow-x` rather than visibly overflowing.

Then at desktop width, confirm the pills reappear and the Community pill is
filled and unclickable on `/community`.

Kill the server by port when done.

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/live/game_live/ priv/static/assets/css/app.css test/rule_maven_web/live/game_subbar_parity_test.exs
git commit -m "feat(subbar): pin the same full-bleed bar to every game screen"
```

---

### Task 5: Update the component's moduledoc

The moduledoc says the bar is "under the game header" and that painting More-menu
destinations as loose links "is showing the same destination twice." Both are now
misleading: the bar *is* the header, and the pills are a deliberate desktop
shortcut. A doc that contradicts the code is worse than no doc.

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex:2-8, 22-31`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing.

- [ ] **Step 1: Rewrite the moduledoc**

```elixir
  @moduledoc """
  The bar every user-facing game screen wears. `game_bar/1` is the public entry
  point: full-bleed chrome, pinned to the top of the scroll container, wrapping a
  header row of `←` back to the games list, the game name, three group menus
  (🎲 Play · 📚 Learn · 💬 More), and the right-hand pills.

  Always rendered — empty state and mid-conversation alike — so the table tools
  stay one tap away. Mobile-first: at 390px the pills hide and the three short
  menu pills fit one row.

  The pills (Rulebooks, Community Q&A, Cheat Sheet) duplicate More-menu items on
  purpose: they are `hide-mobile` desktop shortcuts, and More is the mobile path
  to the same destinations. Anything reachable from the bar belongs in the More
  menu; not everything in the More menu earns a pill.

  Pages pass `current` — the page they are on. It decides whether Overview
  patches (`:show`) or navigates (everywhere else; patching across LiveViews
  crashes), and renders the pill pointing at the current page inert.
  """
```

Replace `game_header/1`'s `@doc` (lines 22-31) with:

```elixir
  @doc """
  The header row itself. An implementation detail of `game_bar/1` — call that
  instead, so the chrome comes with it.
  """
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile --force --warnings-as-errors 2>&1 | tee tmp/subbar-t5.log
```

Expected: no output, no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven_web/live/game_live/sub_bar.ex
git commit -m "docs(subbar): describe the bar the code actually renders"
```

---

## Self-Review Notes

**Spec coverage.** Chrome → Task 4. Pills → Task 3. Sticky → Task 4. `current`
attr → Task 1. `has_cheatsheet` assign → Task 2. `↻ Regen` gate → Task 3.
`padding-top: 0` → Task 4. Opaque background → Task 4. Template hoists → Task 4.
Show's slot reduced to `☰` → Task 3 (slot content), Task 4 (wrapper). Tests →
Tasks 1, 3, 4. 390px verification → Task 4 Step 8. Out-of-scope items
(cheatsheet controller, admin pages, More-menu contents) get no task, correctly.

**Naming consistency.** `current`, `has_cheatsheet`, `game_bar/1`,
`header_pills/1`, `ToolHost.has_cheatsheet?/1`, `.game-bar` — each spelled the
same in every task that mentions it.

**Known sharp edge, handled in Task 2 Step 3.** The existing `put_new/3` takes a
zero-arity callback, so `:has_cheatsheet` could not read the `:sources` that an
earlier `put_new` in the same pipe just assigned. Task 2 changes `put_new/3` to
pass the accumulated socket, and updates all five callbacks together.
