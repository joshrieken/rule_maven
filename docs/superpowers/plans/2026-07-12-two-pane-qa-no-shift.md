# Two-pane Q&A (zero layout shift) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the Q&A screen so the answer lives in its own fixed-height scroll region — the page/frame never moves when an answer streams in, swaps from placeholder, gains trailing chips, or gets restyled.

**Architecture:** The `#chat-messages` appended-bubble list becomes a fixed three-row frame: a non-scrolling question chip (row 1), the answer as the single `overflow-y:auto` scroll region pinned to top with no stream-following (row 2), and a fixed composer (row 3). Trailing chips (followups, also-asked, suggested, "Ask exactly this") render as the tail of the answer scroll content. A tap on the chip opens the full question as an overlay over the answer. A `N/M` pager walks the current thread's Q&As, replacing the answer content rather than appending. Server-side ask pipeline is untouched.

**Tech Stack:** Phoenix LiveView (HEEx), Elixir/ExUnit + `Phoenix.LiveViewTest`, `phoenix_test_playwright` for feature tests, vanilla JS hooks (`assets/js/app.js`), plain CSS (`assets/css/app.css`).

## Global Constraints

- **Mobile-first, verify at 390px** — every UI change verified at 390px width (hard rule).
- **Zero warnings, zero failures** — no compiler warnings, no red tests; `--warnings-as-errors` must stay usable.
- **Run only necessary tests** — only files relevant to this change; no full suite unless asked.
- **Test-run logging** — tee test output to `./tmp` log; don't run the suite twice; clean up after.
- **Auto-commit** completed work; do **not** push.
- **Contrast floors** — WCAG floors enforced by tests; fix the fill, not just the text.
- **Button system** — reuse shared `btn-*` classes; no fresh inline button styles; one primary per row.
- Source of truth for design: `docs/superpowers/specs/2026-07-12-two-pane-qa-no-shift-design.md`.

---

## File Structure

- `assets/css/app.css` — `.chat-layout` becomes the fixed three-row column; new `.answer-pane` scroll class; new `.qa-chip` / `.qa-overlay` styles; drop append-model animations.
- `assets/js/app.js` — `Hooks.ChatScroll` replaced by `Hooks.AnswerPane` (pin-to-top, no follow).
- `lib/rule_maven_web/live/game_live/show.ex` — `render/1` template restructured into the frame; pager assigns + events; question-overlay toggle; removal of `scroll_bottom`/`scroll_top`/`scroll_to_latest` pushes.
- `test/rule_maven_web/live/game_live/qa_no_shift_test.exs` — new LiveViewTest for pager + single-active-Q&A rendering.
- `test/rule_maven_web/features/qa_no_shift_test.exs` — new Playwright 390px no-shift + pin-to-top + overlay test.

---

### Task 1: Fixed three-row frame CSS

**Files:**
- Modify: `assets/css/app.css:1037-1061` (`.chat-layout` block + append animations)
- Modify: `assets/css/app.css` (add `.answer-pane`, `.qa-chip`, `.qa-overlay` near the `.chat-layout` block)

**Interfaces:**
- Produces: CSS classes `.answer-pane` (single scroll region), `.qa-chip` (row 1), `.qa-overlay` + `.qa-overlay__sheet` (full-question overlay). The template (Task 3–5) consumes these class names.

- [ ] **Step 1: Convert `.chat-layout` to a fixed three-row column**

Replace `assets/css/app.css:1037-1048` (the `.chat-layout` animation block and its three child-animation rules) with:

```css
/* Q&A screen: fixed three-row frame. Only the middle row (.answer-pane)
   scrolls, so a growing/streaming answer never moves the chip or composer.
   100dvh (not vh) keeps the composer above the mobile browser chrome and the
   on-screen keyboard. */
.chat-layout {
  display: flex;
  flex-direction: column;
  height: 100dvh;
  min-height: 0;
  animation: qa-panel-in 0.4s cubic-bezier(0.16, 1, 0.3, 1) both;
}
.chat-layout .chat-header {
  flex: 0 0 auto;
  animation: qa-drop-in 0.45s cubic-bezier(0.16, 1, 0.3, 1) 0.06s both;
}
.chat-layout .chat-input {
  flex: 0 0 auto;
  animation: qa-rise-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) 0.22s both;
}
```

(Note: the old `.chat-layout .chat-messages` rise-in rule is intentionally dropped — the answer pane must not animate its height. Keep the `qa-panel-in` / `qa-drop-in` / `qa-rise-in` keyframes at `:1050-1061`; they are still referenced.)

- [ ] **Step 2: Add the answer-pane scroll class + chip + overlay**

Insert immediately after the block from Step 1:

```css
/* The one scroll region. flex:1 + min-height:0 lets it take the leftover
   height and scroll internally; the frame around it stays put. */
.answer-pane {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 1rem;
  max-width: 48rem;
  margin: 0 auto;
  width: 100%;
  background: var(--bg);
  position: relative;
  z-index: 1;
}

/* Row 1: non-scrolling question chip. One line, truncated, tappable. */
.qa-chip {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
  font-size: 0.85rem;
  color: var(--text);
}
.qa-chip__text {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
.qa-chip__pager {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  flex: 0 0 auto;
  color: var(--text-secondary);
  font-size: 0.78rem;
}

/* Full-question overlay: sits OVER the answer pane, never pushes it. */
.qa-overlay {
  position: absolute;
  inset: 0;
  z-index: 20;
  display: flex;
  align-items: flex-start;
  justify-content: center;
  background: color-mix(in srgb, var(--bg) 60%, transparent);
  backdrop-filter: blur(2px);
}
.qa-overlay__sheet {
  margin: 0.75rem;
  max-width: 44rem;
  width: 100%;
  padding: 1rem 1.1rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 0.75rem;
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.18);
  font-size: 0.95rem;
  line-height: 1.45;
  color: var(--text);
}
```

- [ ] **Step 3: Verify the build compiles the CSS**

Run: `cd /Users/facto/development/personal/rule_maven && mix assets.build 2>&1 | tee tmp/task1-assets.log`
Expected: exits 0, no CSS errors in the log.

- [ ] **Step 4: Commit**

```bash
git add assets/css/app.css
git commit -m "feat(ask): fixed three-row Q&A frame CSS, single scroll region"
```

---

### Task 2: AnswerPane JS hook (pin-to-top, no follow)

**Files:**
- Modify: `assets/js/app.js:169-224` (replace `Hooks.ChatScroll`)

**Interfaces:**
- Produces: `Hooks.AnswerPane`, attached via `phx-hook="AnswerPane"` on the `.answer-pane` element (Task 3). Handles a `reset_answer_scroll` LiveView event (pushed by pager/thread switch in Task 5). No `scroll_bottom` / `scroll_top` / `scroll_to_latest` handlers.

- [ ] **Step 1: Replace the ChatScroll hook**

Replace `assets/js/app.js:169-224` (the entire `Hooks.ChatScroll = { ... };` block) with:

```javascript
Hooks.AnswerPane = {
  mounted() {
    // The frame owns the viewport; only this pane scrolls internally.
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    this.activeKey = this.el.dataset.answerKey || "";
    this.el.scrollTop = 0;
    // Pager / thread switch asks us to re-pin to the top of the new answer.
    this.handleEvent("reset_answer_scroll", () => this.pinTop());
  },
  updated() {
    // Pin to top ONLY when the active Q&A actually changed (new question or
    // pager step). Streaming tokens, votes, restyle, sidebar toggles all keep
    // the same key — we must NOT move the scroll for those (that was the yank).
    const key = this.el.dataset.answerKey || "";
    if (key !== this.activeKey) {
      this.activeKey = key;
      this.pinTop();
    }
  },
  destroyed() {
    document.documentElement.style.overflow = "";
    document.body.style.overflow = "";
  },
  pinTop() {
    requestAnimationFrame(() => {
      this.el.scrollTop = 0;
    });
  }
};
```

- [ ] **Step 2: Verify no dangling references to the old hook**

Run: `cd /Users/facto/development/personal/rule_maven && grep -rn "ChatScroll\|scrollToLatestAnswer\|scroll_bottom\|scroll_top\|scroll_to_latest" assets/js lib | tee tmp/task2-grep.log`
Expected: only matches inside `lib/.../show.ex` (the server pushes, removed in Task 5). Zero matches in `assets/js`. If any remain in `assets/js`, remove them.

- [ ] **Step 3: Build assets**

Run: `cd /Users/facto/development/personal/rule_maven && mix assets.build 2>&1 | tee tmp/task2-assets.log`
Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add assets/js/app.js
git commit -m "feat(ask): AnswerPane hook pins to top, drops stream auto-follow"
```

---

### Task 3: Restructure the template into the frame

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:3600-3606` (the `#chat-messages` opening div)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (the message loop `:3729`, and add the chip row above the pane)

**Interfaces:**
- Consumes: `@conversation` (list of message maps), `@active_thread_id`, existing assigns.
- Produces: the `.answer-pane` element carrying `phx-hook="AnswerPane"` and `data-answer-key`; the `.qa-chip` row. Task 5 supplies `@qa_active_index` / `@qa_total` / `@qa_active_question` used by the chip.

- [ ] **Step 1: Add the chip row and convert the messages div to `.answer-pane`**

Replace the opening of the messages container at `show.ex:3600-3606`:

```elixir
        <!-- Messages -->
        <div
          id="chat-messages"
          class="chat-messages"
          style="flex:1;overflow-y:auto;overflow-x:hidden;padding:1rem;display:flex;flex-direction:column;gap:1rem;background:var(--bg);max-width:48rem;margin:0 auto;width:100%;min-width:0;position:relative;z-index:1"
          phx-hook="ChatScroll"
        >
```

with (the chip renders only once a conversation exists; the empty state stays inside the pane):

```elixir
        <!-- Row 1: question chip (fixed, never scrolls) -->
        <%= if @conversation != [] && @qa_active_question do %>
          <div class="qa-chip">
            <button
              type="button"
              class="qa-chip__pager"
              phx-click="qa_prev"
              disabled={@qa_active_index <= 0}
              aria-label="Previous question"
            >◂</button>
            <span
              class="qa-chip__text"
              phx-click="qa_show_question"
              title="Show full question"
            >{@qa_active_question}</span>
            <span class="qa-chip__pager">{@qa_active_index + 1} / {@qa_total}</span>
            <button
              type="button"
              class="qa-chip__pager"
              phx-click="qa_next"
              disabled={@qa_active_index >= @qa_total - 1}
              aria-label="Next question"
            >▸</button>
          </div>
        <% end %>

        <!-- Row 2: the ONE scroll region -->
        <div
          id="chat-messages"
          class="answer-pane"
          data-answer-key={"#{@active_thread_id}-#{@qa_active_index}"}
          phx-hook="AnswerPane"
        >
```

- [ ] **Step 2: Add the overlay inside the pane**

Immediately after the `.answer-pane` opening div (before the `@source_count == 0` block at `:3607`), add:

```elixir
          <%= if @qa_show_question do %>
            <div class="qa-overlay" phx-click="qa_hide_question">
              <div class="qa-overlay__sheet" phx-click="ignore">
                {@qa_active_question}
              </div>
            </div>
          <% end %>
```

(The inner `phx-click="ignore"` stops a tap on the sheet from closing it; add a no-op `handle_event("ignore", _, socket)` in Task 5.)

- [ ] **Step 3: Verify template compiles**

Run: `cd /Users/facto/development/personal/rule_maven && mix compile --warnings-as-errors 2>&1 | tee tmp/task3-compile.log`
Expected: FAIL — `@qa_active_question` / `@qa_active_index` / `@qa_total` / `@qa_show_question` are undefined assigns (added in Task 5). This confirms the template references the new assigns; proceed to Task 4/5 before re-running.

- [ ] **Step 4: Commit (WIP frame)**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat(ask): render question chip + answer-pane frame (assigns pending)"
```

---

### Task 4: Move trailing chips into the answer scroll content

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:4073-4130` (followups / also-asked / refusal suggestions) and `:4002-4023` ("Ask exactly this")

**Interfaces:**
- Consumes: existing `has_followups` / `has_also` logic and `answer_ready?` gate.
- Produces: these blocks now sit at the bottom of the `.answer-pane` content (inside the scroll region), not as siblings after it.

- [ ] **Step 1: Confirm the trailing blocks are inside `.answer-pane`**

The followup/also-asked block (`:4073`), refusal suggestions (`:4112`), and "Ask exactly this" (`:4002-4023`) are rendered per-message inside the `@conversation` loop, which is inside the messages div. After Task 3 that div is `.answer-pane`, so they are already inside the single scroll region. **No move needed if they render within the loop.**

Run: `cd /Users/facto/development/personal/rule_maven && sed -n '3729,4135p' lib/rule_maven_web/live/game_live/show.ex | grep -n "Related questions\|ask_exactly\|refusal" | tee tmp/task4-scope.log`
Expected: line numbers confirming these blocks fall between the loop start (`:3729`) and the pane close. If any block sits AFTER the `</div>` that closes `#chat-messages`, move it to just before that closing tag.

- [ ] **Step 2: Remove the reserved-slot shift mechanism**

The reserved-slot markup at `:4011` existed only to stop trailing chips pushing the answer down in the append model. With the fixed pane it is dead weight. Locate the reserved-slot block (search `reserved slot` / the disabled-while-streaming spacer near `:4011`) and delete only the empty spacer element, keeping the `answer_ready?` gate (`:4005`) that disables "Ask exactly this" while streaming.

Run: `cd /Users/facto/development/personal/rule_maven && grep -n "answer_ready?\|ask_exactly" lib/rule_maven_web/live/game_live/show.ex | tee tmp/task4-gate.log`
Expected: `answer_ready?` and `ask_exactly` still present (gate kept); the spacer gone.

- [ ] **Step 3: Compile (still expected to fail on missing assigns)**

Run: `cd /Users/facto/development/personal/rule_maven && mix compile --warnings-as-errors 2>&1 | tee tmp/task4-compile.log`
Expected: still FAIL on `@qa_*` assigns only (resolved in Task 5). No new errors introduced by this task.

- [ ] **Step 4: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat(ask): trailing chips ride inside answer pane; drop reserved slot"
```

---

### Task 5: Pager + overlay state and events

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — mount/assigns, new `handle_event`s, remove scroll pushes at `:371,513,1656`
- Test: `test/rule_maven_web/live/game_live/qa_no_shift_test.exs` (new)

**Interfaces:**
- Consumes: `@conversation` (assistant/user message pairs), `@active_thread_id`.
- Produces assigns:
  - `@qa_total` (integer) — number of Q&As in the current thread.
  - `@qa_active_index` (0-based integer) — which Q&A the pane shows; defaults to the last (newest) on a fresh answer.
  - `@qa_active_question` (string | nil) — the active question's text for the chip/overlay.
  - `@qa_show_question` (boolean) — overlay open/closed.
- Produces events: `qa_prev`, `qa_next`, `qa_show_question`, `qa_hide_question`, `ignore`.
- Produces: a `assign_qa_nav/1` helper that derives `@qa_total` / `@qa_active_question` from `@conversation` and clamps `@qa_active_index`.

- [ ] **Step 1: Write the failing LiveViewTest**

Create `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`:

```elixir
defmodule RuleMavenWeb.GameLive.QaNoShiftTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  setup do
    # Reuse the project's fixture that builds a game with a source and a
    # two-Q&A thread. If no such fixture exists, build one here.
    %{game: game, user: user} = qa_thread_fixture(question_count: 2)
    %{game: game, user: user}
  end

  test "renders exactly one active Q&A with a pager, not an appended list",
       %{conn: conn, game: game, user: user} do
    {:ok, view, html} =
      conn |> log_in_user(user) |> live(~p"/games/#{game}")

    # One answer-pane, one chip showing "1 / 2" style pager.
    assert html =~ ~s(class="answer-pane")
    assert has_element?(view, ".qa-chip__pager", "2")
    # Only one assistant answer body is visible at a time (pane shows active).
    assert view |> element(".answer-pane") |> render() =~ "answer"
  end

  test "pager next/prev swaps the active question", %{conn: conn, game: game, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game}")

    q1 = view |> element(".qa-chip__text") |> render()
    view |> element("button[phx-click=qa_prev]") |> render_click()
    q0 = view |> element(".qa-chip__text") |> render()
    refute q0 == q1
  end

  test "tapping the chip opens the full-question overlay", %{conn: conn, game: game, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/games/#{game}")

    refute has_element?(view, ".qa-overlay")
    view |> element(".qa-chip__text") |> render_click()
    assert has_element?(view, ".qa-overlay__sheet")
    view |> element(".qa-overlay") |> render_click()
    refute has_element?(view, ".qa-overlay")
  end
end
```

- [ ] **Step 2: Run it — expect failure**

Run: `cd /Users/facto/development/personal/rule_maven && mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs 2>&1 | tee tmp/task5-red.log`
Expected: FAIL — assigns/events undefined, or `qa_thread_fixture` missing. If the fixture helper does not exist, add it to `test/support/fixtures/games_fixtures.ex` building a game + source + a thread with `question_count` user/assistant pairs, then re-run to reach the assertion failures.

- [ ] **Step 3: Add the `assign_qa_nav/1` helper**

Add near the other assign helpers in `show.ex`:

```elixir
  # Derives chip/pager state from the current thread's conversation. A "Q&A" is
  # a user message paired with its assistant answer; index is 0-based over those
  # pairs, newest last. Clamps the active index so removing/switching threads
  # can't leave it out of range.
  defp assign_qa_nav(socket) do
    questions =
      socket.assigns.conversation
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(& &1.content)

    total = length(questions)
    default_index = max(total - 1, 0)

    index =
      socket.assigns
      |> Map.get(:qa_active_index, default_index)
      |> min(max(total - 1, 0))
      |> max(0)

    socket
    |> assign(:qa_total, total)
    |> assign(:qa_active_index, index)
    |> assign(:qa_active_question, Enum.at(questions, index))
    |> assign(:qa_show_question, Map.get(socket.assigns, :qa_show_question, false))
  end
```

- [ ] **Step 4: Initialize assigns and call the helper**

In `mount/3` (or the assign path that sets `@conversation`), add defaults before first render:

```elixir
    |> assign(:qa_active_index, nil)
    |> assign(:qa_show_question, false)
```

Then call `assign_qa_nav/1` everywhere `@conversation` changes — at minimum after mount's conversation load, after a new answer is appended, and after a thread switch. On a **fresh answer arriving**, reset to newest by clearing the index first:

```elixir
    socket |> assign(:qa_active_index, nil) |> assign_qa_nav()
```

(`nil` → `assign_qa_nav` picks `default_index`, the newest.)

- [ ] **Step 5: Add the pager/overlay events**

Add these `handle_event/3` clauses (place beside the page's first `handle_event`, per the sub-bar convention):

```elixir
  def handle_event("qa_prev", _params, socket) do
    index = max(socket.assigns.qa_active_index - 1, 0)
    {:noreply,
     socket
     |> assign(:qa_active_index, index)
     |> assign_qa_nav()
     |> push_event("reset_answer_scroll", %{})}
  end

  def handle_event("qa_next", _params, socket) do
    index = min(socket.assigns.qa_active_index + 1, max(socket.assigns.qa_total - 1, 0))
    {:noreply,
     socket
     |> assign(:qa_active_index, index)
     |> assign_qa_nav()
     |> push_event("reset_answer_scroll", %{})}
  end

  def handle_event("qa_show_question", _params, socket) do
    {:noreply, assign(socket, :qa_show_question, true)}
  end

  def handle_event("qa_hide_question", _params, socket) do
    {:noreply, assign(socket, :qa_show_question, false)}
  end

  def handle_event("ignore", _params, socket), do: {:noreply, socket}
```

- [ ] **Step 6: Show only the active Q&A in the pane**

The `@conversation` loop at `:3729` currently renders every message. Change it to render only the active Q&A pair (the user message at `@qa_active_index` and its assistant answer). Replace the loop guard so it filters to the active pair:

```elixir
          <%= for {msg, idx} <- active_qa_messages(@conversation, @qa_active_index) do %>
```

and add the helper:

```elixir
  # Returns the {message, original_index} tuples for the active Q&A pair only:
  # the Nth user message plus every assistant/history message up to the next
  # user message. Keeps history-collapse and streaming markup working unchanged.
  defp active_qa_messages(conversation, active_index) do
    indexed = Enum.with_index(conversation)

    user_positions =
      for {%{role: :user}, i} <- indexed, do: i

    start_i = Enum.at(user_positions, active_index) || 0
    next_i = Enum.at(user_positions, active_index + 1) || length(conversation)

    Enum.filter(indexed, fn {_msg, i} -> i >= start_i and i < next_i end)
  end
```

- [ ] **Step 7: Remove the scroll pushes**

Delete the `push_event("scroll_top", ...)` calls at `show.ex:371` and `:513` and the `push_event("scroll_bottom", ...)` at `:1656`. Where a thread switch happened (`:371`), replace with `push_event("reset_answer_scroll", %{})` and `assign(:qa_active_index, nil)` so the pane pins to the newest Q&A of the incoming thread.

Run: `cd /Users/facto/development/personal/rule_maven && grep -n "scroll_bottom\|scroll_top\|scroll_to_latest" lib/rule_maven_web/live/game_live/show.ex | tee tmp/task5-pushes.log`
Expected: zero matches.

- [ ] **Step 8: Run the LiveViewTest — expect pass**

Run: `cd /Users/facto/development/personal/rule_maven && mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs 2>&1 | tee tmp/task5-green.log`
Expected: PASS (3 tests).

- [ ] **Step 9: Full compile, warnings as errors**

Run: `cd /Users/facto/development/personal/rule_maven && mix compile --warnings-as-errors 2>&1 | tee tmp/task5-compile.log`
Expected: exits 0, no warnings.

- [ ] **Step 10: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/qa_no_shift_test.exs test/support/fixtures/games_fixtures.ex
git commit -m "feat(ask): pager + overlay state, active-Q&A pane, drop scroll pushes"
```

---

### Task 6: 390px no-shift feature test

**Files:**
- Test: `test/rule_maven_web/features/qa_no_shift_test.exs` (new)

**Interfaces:**
- Consumes: the running LiveView at `/games/:id`; `phoenix_test_playwright` driver.

- [ ] **Step 1: Write the failing feature test**

Create `test/rule_maven_web/features/qa_no_shift_test.exs`:

```elixir
defmodule RuleMavenWeb.Features.QaNoShiftTest do
  use RuleMavenWeb.FeatureCase, async: false
  import PhoenixTest

  @moduletag :playwright

  # 390px = the mobile-first hard-rule width.
  setup %{conn: conn} do
    %{game: game, user: user} = RuleMaven.GamesFixtures.qa_thread_fixture(question_count: 1)
    conn = log_in_user(conn, user)
    %{conn: conn, game: game}
  end

  test "composer does not move between thinking, streaming, and complete", %{conn: conn, game: game} do
    session =
      conn
      |> visit(~p"/games/#{game}")
      |> set_viewport(390, 844)

    # Record the composer's top before asking.
    top_before = composer_top(session)

    session
    |> fill_in("Ask a rules question", with: "Can I stack a Draw 4 on a Draw 2?")
    |> click_button("Ask")

    # While thinking and after the answer resolves, the composer must not move.
    top_thinking = composer_top(session)
    session = assert_has(session, ".verdict-stamp", timeout: 30_000)
    top_done = composer_top(session)

    assert_in_delta top_before, top_thinking, 1.0
    assert_in_delta top_before, top_done, 1.0
  end

  test "answer pane is pinned to top on a fresh answer", %{conn: conn, game: game} do
    session =
      conn
      |> visit(~p"/games/#{game}")
      |> set_viewport(390, 844)
      |> fill_in("Ask a rules question", with: "Long rules question that yields a long answer")
      |> click_button("Ask")
      |> assert_has(".verdict-stamp", timeout: 30_000)

    assert scroll_top(session, ".answer-pane") == 0
  end

  # Helpers read layout geometry via the driver's evaluate hook.
  defp composer_top(session), do: bounding_top(session, ".chat-input")
  defp bounding_top(session, sel) do
    session |> unwrap(fn page ->
      page |> Playwright.Page.locator(sel) |> Playwright.Locator.bounding_box() |> Map.get("y")
    end)
  end
  defp scroll_top(session, sel) do
    session |> unwrap(fn page ->
      Playwright.Page.eval_on_selector(page, sel, "el => el.scrollTop")
    end)
  end
end
```

(Adapt `set_viewport` / `unwrap` / `composer_top` to the project's actual `phoenix_test_playwright` helper names — see `test/support/feature_case.ex` and the existing 390px feature tests for the exact API. The assertion that matters: `.chat-input` bounding-box `y` is unchanged across states, and `.answer-pane` `scrollTop == 0`.)

- [ ] **Step 2: Run it — expect failure or driver-shape errors first**

Run: `cd /Users/facto/development/personal/rule_maven && mix test test/rule_maven_web/features/qa_no_shift_test.exs 2>&1 | tee tmp/task6-red.log`
Expected: FAIL. Fix helper names against the existing feature-test API until the assertions run, then the real assertions should PASS if Tasks 1–5 are correct.

- [ ] **Step 3: Run to green**

Run: `cd /Users/facto/development/personal/rule_maven && mix test test/rule_maven_web/features/qa_no_shift_test.exs 2>&1 | tee tmp/task6-green.log`
Expected: PASS (2 tests). If the composer moves, the frame height (`100dvh`) or a stray non-`flex:0 0 auto` row is the cause — inspect `.chat-layout` children.

- [ ] **Step 4: Commit**

```bash
git add test/rule_maven_web/features/qa_no_shift_test.exs
git commit -m "test(ask): 390px no-shift + pin-to-top feature test"
```

---

### Task 7: Manual 390px verification + cleanup

**Files:** none (verification only)

- [ ] **Step 1: Run the app and verify at 390px**

Run: `cd /Users/facto/development/personal/rule_maven && grep -rn "mix phx.server" . --include=*.md | head -1`
Then start the dev server per the project's normal command (do **not** start a worktree server — shared Oban queue). Open `/games/:id` at 390px width and:
- Ask a question; watch the composer and chip — neither may move during thinking, streaming, or completion.
- Confirm the answer pane sits scrolled to top when the answer appears; scroll down to reach followup/suggested chips.
- Tap the chip → full question overlays the answer without moving it; tap the backdrop to dismiss.
- Page prev/next; the answer swaps and re-pins to top.
- Open the on-screen keyboard (tap the input) — the composer stays visible above it (this is the `100dvh` check).

- [ ] **Step 2: Remove temporary logs**

Run: `cd /Users/facto/development/personal/rule_maven && rm -f tmp/task*.log`

- [ ] **Step 3: Final necessary-tests run**

Run: `cd /Users/facto/development/personal/rule_maven && mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs test/rule_maven_web/features/qa_no_shift_test.exs 2>&1 | tee tmp/final.log; rm -f tmp/final.log`
Expected: all PASS, zero warnings.

- [ ] **Step 4: Commit any cleanup**

```bash
git add -A
git commit -m "chore(ask): two-pane Q&A no-shift verification cleanup" || echo "nothing to commit"
```

---

## Self-Review Notes

- **Spec coverage:** frame (Task 1/3), pin-to-top no-follow (Task 2), overlay expand (Task 3/5), pager over current thread (Task 5), trailing chips inside pane (Task 4), error/refusal/persona inherit no-shift via rendering inside row 2 (Task 4 — they live in the loop), 390px + `100dvh` keyboard risk (Task 6/7). All spec sections mapped.
- **Naming consistency:** `data-answer-key` (Task 3) ↔ `dataset.answerKey` (Task 2); `reset_answer_scroll` pushed in Task 5, handled in Task 2; `assign_qa_nav/1`, `active_qa_messages/2`, `@qa_active_index/@qa_total/@qa_active_question/@qa_show_question` used identically across Tasks 3/5.
- **Known adaptation points (not placeholders):** the fixture helper `qa_thread_fixture/1` and the `phoenix_test_playwright` helper API (`set_viewport`, `unwrap`, bounding box) must be matched to what the repo actually exposes — Task 5 Step 2 and Task 6 Step 1 call this out explicitly with where to look.
