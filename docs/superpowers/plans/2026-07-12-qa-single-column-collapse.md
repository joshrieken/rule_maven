# Q&A Single-Column Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the dead middle gradient pane on the Q&A screen into a single Q&A column so the active question renders once (its answer-pane bubble) with a slim fixed pager on top.

**Architecture:** The Q&A screen's horizontal flex row (`show.ex:3488`) currently holds `#question-sidebar`, `.qa-chip`, and `.answer-pane` as three siblings; the chip floats left while the answer-pane centers right, leaving a dead gradient gap. Wrap the chip + answer-pane in one vertical flex column so they stack (fixed slim pager on top, scrolling answer below) as the single `flex:1` sibling of the sidebar. Strip the chip's duplicated question text and remove the now-dead full-question overlay.

**Tech Stack:** Phoenix LiveView (HEEx in `lib/rule_maven_web/live/game_live/show.ex`), plain CSS (`priv/static/assets/css/app.css`, no bundler — edit the served file directly), `phoenix_test` + LiveViewTest.

## Global Constraints

- No asset bundler: edit `priv/static/assets/css/app.css` directly (the served file is the source of truth).
- Mobile-first hard rule: verify every change at 390px — no horizontal scroll, pager bar must not wrap, zero layout shift while an answer streams.
- Zero warnings, zero failures: the full targeted test set must pass; no "pre-existing" excuses.
- Preserve the shipped zero-layout-shift guarantee: the pager stays `flex:0 0 auto` (fixed) above the one scroll region (`.answer-pane`), so streaming never moves the pager or composer.
- Keep the container class name `.qa-chip` (restyle in place) to limit selector churn; only `.qa-chip__text` and the `.qa-overlay*` classes are removed.

---

### Task 1: Wrap pager + answer-pane in one vertical column

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (insert wrapper open ~line 3702, wrapper close after the `.answer-pane` closes at ~line 4924)
- Test: `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`

**Interfaces:**
- Consumes: existing assigns `@conversation`, `@qa_active_question`, `@active_thread_id`.
- Produces: a `.qa-column` wrapper `<div>` that is the single `flex:1` sibling of `#question-sidebar` in the row at `show.ex:3488`, containing the `.qa-chip` block and the `#chat-messages.answer-pane` block.

- [ ] **Step 1: Confirm the current one-column-after-sidebar assertion fails today**

  The existing test `test/rule_maven_web/live/game_live/qa_no_shift_test.exs` already asserts `.answer-pane` renders. Add a temporary guard test at the end of the `describe` block to prove the chip and answer-pane are NOT yet wrapped together:

  ```elixir
  test "pager and answer-pane share one vertical column wrapper",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)
    # .qa-column wraps both the pager bar and the scroll region.
    assert has_element?(view, ".qa-column .qa-chip__pager")
    assert has_element?(view, ".qa-column .answer-pane")
  end
  ```

- [ ] **Step 2: Run it, verify it fails**

  Run: `mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs:<new-line> --warnings-as-errors`
  Expected: FAIL — no `.qa-column` element exists yet.

- [ ] **Step 3: Insert the vertical column wrapper**

  In `lib/rule_maven_web/live/game_live/show.ex`, immediately AFTER the voice-default-store div (`<div id="voice-default-store" phx-hook="VoiceDefault" style="display:none"></div>`, ~line 3701) and BEFORE the `<!-- Row 1: question chip ... -->` comment, open the wrapper:

  ```heex
  <%!-- One Q&A column: fixed pager bar on top, scrolling answer below.
        This is the single flex:1 sibling of the sidebar; the answer-pane
        (max-width:48rem, margin:auto) centers inside it as a reading column. --%>
  <div class="qa-column" style="flex:1;min-width:0;display:flex;flex-direction:column">
  ```

  Then find where `.answer-pane` closes. The `#chat-messages` div opens at ~line 3731 and closes at the `</div>` on ~line 4924 (the `</div>` on the following line, ~4925, closes the horizontal row from line 3488). Insert the wrapper's closing tag BETWEEN them — after the answer-pane's `</div>` and before the row's `</div>`:

  ```heex
        </div><%!-- /.answer-pane --%>
      </div><%!-- /.qa-column --%>
    </div><%!-- /horizontal row --%>
  ```

  (Match the existing indentation. The three closes are: answer-pane, then the new `.qa-column`, then the pre-existing horizontal row.)

- [ ] **Step 4: Run the test, verify it passes**

  Run: `mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs --warnings-as-errors`
  Expected: PASS (the new wrapper test passes; the overlay/text tests still pass — untouched this task).

- [ ] **Step 5: Commit**

  ```bash
  git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/qa_no_shift_test.exs
  git commit -m "feat(ask): wrap pager + answer-pane in one vertical Q&A column"
  ```

---

### Task 2: Slim the chip — drop the duplicated question text, center the pager

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (remove `.qa-chip__text` button, ~lines 3713-3718)
- Modify: `priv/static/assets/css/app.css` (remove `.qa-chip__text`; center `.qa-chip`; refresh stale comment)
- Test: `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`

**Interfaces:**
- Consumes: `@qa_active_index`, `@qa_total` (pager position), `qa_prev` / `qa_next` handlers (unchanged).
- Produces: `.qa-chip` containing only the two `qa-chip__pager` buttons and the `N / M` count span; the active question text no longer renders in the chip (it renders once, as the `.chat-msg-user` bubble in `.answer-pane`).

- [ ] **Step 1: Rewrite the paging test to read the question from the answer bubble, and assert the chip has no text button**

  In `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`, replace the body of `test "pager next/prev swaps the active question"` so it reads the active question from the user bubble instead of the removed `.qa-chip__text`:

  ```elixir
  test "pager next/prev swaps the active question",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    # The chip no longer echoes the question — read it from the one place it
    # renders, the user bubble in the scroll region.
    refute has_element?(view, ".qa-chip__text")
    q1 = view |> element(".chat-msg-user") |> render()
    view |> element("button[phx-click=qa_next]") |> render_click()
    q0 = view |> element(".chat-msg-user") |> render()
    refute q0 == q1
  end
  ```

- [ ] **Step 2: Run it, verify it fails**

  Run: `mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs:35 --warnings-as-errors`
  Expected: FAIL on `refute has_element?(view, ".qa-chip__text")` — the text button still renders.

- [ ] **Step 3: Remove the `.qa-chip__text` button from the markup**

  In `lib/rule_maven_web/live/game_live/show.ex`, delete the question-text button inside `.qa-chip` (~lines 3713-3718):

  ```heex
          <button
            type="button"
            class="qa-chip__text"
            phx-click="qa_show_question"
            title="Show full question"
          >{@qa_active_question}</button>
  ```

  Leave the two `qa-chip__pager` buttons and the `{@qa_active_index + 1} / {@qa_total}` count span in place.

- [ ] **Step 4: Center the pager and drop dead CSS**

  In `priv/static/assets/css/app.css`:
  - Add `justify-content: center;` to the `.qa-chip` rule (~line 1072) so the remaining `◂ N / M ▸` controls center in the slim bar.
  - Delete the entire `.qa-chip__text { ... }` rule (~lines 1083-1096).
  - Update the stale comment above `.qa-chip` (~line 1071) from "Row 1: non-scrolling question chip. One line, truncated, tappable." to: `/* Slim fixed pager bar atop the Q&A column: prev / N-of-M / next. */`

- [ ] **Step 5: Run tests, verify pass**

  Run: `mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs --warnings-as-errors`
  Expected: PASS for the wrapper and paging tests. (The overlay test at line 48 still passes here — it is removed in Task 3.)

- [ ] **Step 6: Commit**

  ```bash
  git add lib/rule_maven_web/live/game_live/show.ex priv/static/assets/css/app.css test/rule_maven_web/live/game_live/qa_no_shift_test.exs
  git commit -m "feat(ask): drop duplicated question text from chip, center pager"
  ```

---

### Task 3: Remove the now-dead full-question overlay

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (overlay markup ~lines 5249-5261; handlers ~lines 1254-1267; assigns line 185 and ~line 758)
- Modify: `priv/static/assets/css/app.css` (`.qa-overlay`, `.qa-overlay__sheet` ~lines 1106-1129)
- Test: `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`, `test/rule_maven_web/feature/qa_no_shift_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: the `qa_show_question` / `qa_hide_question` / `ignore` handlers and the `@qa_show_question` assign are gone; the full question is only ever the answer-pane bubble.

- [ ] **Step 1: Delete the two overlay tests**

  - In `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`, delete the whole `test "tapping the chip opens the full-question overlay"` block (~lines 48-57).
  - In `test/rule_maven_web/feature/qa_no_shift_test.exs`, delete the regression comment (~lines 263-270) and the whole `test "full-question overlay stays on-screen after the answer pane is scrolled"` block (~lines 271 through its `end`).

- [ ] **Step 2: Remove the overlay markup**

  In `lib/rule_maven_web/live/game_live/show.ex`, delete the overlay comment and block that is a direct child of `.chat-layout` (~lines 5249-5261):

  ```heex
      <%!-- Direct child of .chat-layout (fixed frame) ... --%>
      <%= if @qa_show_question do %>
        <div class="qa-overlay" phx-click="qa_hide_question">
          <div class="qa-overlay__sheet" phx-click="ignore">
            {@qa_active_question}
          </div>
        </div>
      <% end %>
  ```

  (Leave the `</div>` on the next line — it closes `.chat-layout`.)

- [ ] **Step 3: Remove the dead handlers**

  In `lib/rule_maven_web/live/game_live/show.ex`, delete the three handler clauses (~lines 1254-1267): `handle_event("qa_show_question", ...)`, `handle_event("qa_hide_question", ...)`, and the `handle_event("ignore", ...)` no-op plus its `@impl true` and the comment above it (`# The overlay sheet's own click ...`). The `ignore` event has no other caller (verified: only the removed overlay sheet used `phx-click="ignore"`; `phx-update="ignore"` is a different, unaffected directive).

- [ ] **Step 4: Remove the `@qa_show_question` assign**

  In `lib/rule_maven_web/live/game_live/show.ex`:
  - Line 184-185: remove the trailing `qa_show_question: false` from the mount assign list (and fix the preceding comma on `qa_active_question: nil`).
  - ~Line 758: remove the line `|> assign(:qa_show_question, Map.get(socket.assigns, :qa_show_question, false))` from `assign_qa_nav/1`.

- [ ] **Step 5: Remove the overlay CSS**

  In `priv/static/assets/css/app.css`, delete the `.qa-overlay { ... }` and `.qa-overlay__sheet { ... }` rules and the comment above them (~lines 1106-1129, `/* Full-question overlay: ... */`).

- [ ] **Step 6: Run tests, verify pass**

  Run: `mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs --warnings-as-errors`
  Expected: PASS. No reference to `qa_show_question`, `.qa-chip__text`, or `.qa-overlay` remains; the compiler raises no "unused" warning.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/rule_maven_web/live/game_live/show.ex priv/static/assets/css/app.css test/rule_maven_web/live/game_live/qa_no_shift_test.exs test/rule_maven_web/feature/qa_no_shift_test.exs
  git commit -m "refactor(ask): remove dead full-question overlay + handlers"
  ```

---

### Task 4: Refresh stale frame comments and verify end-to-end

**Files:**
- Modify: `priv/static/assets/css/app.css` (stale 3-row-frame comment ~lines 1036-1042)
- Modify: `test/rule_maven_web/feature/qa_no_shift_test.exs` (module doc comment ~lines 10-13)
- Test: both `qa_no_shift` test files.

- [ ] **Step 1: Update the stale layout comments**

  - In `priv/static/assets/css/app.css` (~lines 1036-1042), reword the "fixed three-row frame" comment to describe the current shape: the Q&A column stacks a fixed pager bar over the one scroll region (`.answer-pane`), so a streaming answer never moves the pager or composer.
  - In `test/rule_maven_web/feature/qa_no_shift_test.exs` (~lines 10-13), update the module doc that lists the frame as `.qa-chip` / `.answer-pane` / `.chat-input` — clarify `.qa-chip` is now the pager-only bar at the top of `.qa-column`.

- [ ] **Step 2: Run both Q&A test files**

  Run: `mkdir -p tmp && mix test test/rule_maven_web/live/game_live/qa_no_shift_test.exs test/rule_maven_web/feature/qa_no_shift_test.exs --warnings-as-errors 2>&1 | tee tmp/qa-collapse-test.log`
  Expected: PASS, 0 failures, 0 warnings. (The feature file's composer-no-shift + pin-to-top test must still pass — the pager stays fixed above the scroll region.)

- [ ] **Step 3: Visual verification (major UI change)**

  Per the verify-major-only rule this is a real layout change — drive the actual screen:
  - Desktop: load a game with an active thread; confirm two columns only (sidebar | Q&A column), the question appears once (orange bubble), the slim pager sits centered at the column top, and no dead gradient band remains between sidebar and answer.
  - 390px: confirm the sidebar collapses, the Q&A column is full-width, the pager bar does not wrap, and the composer does not move while an answer streams.

- [ ] **Step 4: Commit**

  ```bash
  rm -f tmp/qa-collapse-test.log
  git add priv/static/assets/css/app.css test/rule_maven_web/feature/qa_no_shift_test.exs
  git commit -m "docs(ask): refresh Q&A frame comments after single-column collapse"
  ```

---

## Self-Review

**Spec coverage:**
- Layout (single Q&A column, sidebar + vertical wrapper) → Task 1.
- Slim pager, drop question-text duplication, centered → Task 2.
- Centered ~48rem reading column → Task 1 (answer-pane keeps its existing `max-width:48rem; margin:auto`, now centering in the full-width `.qa-column` instead of a chip-shrunk flex area — no CSS change needed).
- Remove `qa_show_question` overlay + handlers + assign + CSS + `.qa-chip__text` CSS → Tasks 2 & 3.
- Preserve zero-shift → pager stays `flex:0 0 auto` above `.answer-pane` (Task 1); asserted by the surviving feature test (Task 4 Step 2).
- Mobile 390px verify → Task 4 Step 3.
- Untouched sidebar / answer rendering / composer → no task modifies them.

**Placeholder scan:** none — every step carries exact paths, code, and commands.

**Type/selector consistency:** `.qa-chip` container name kept throughout; `.qa-chip__pager` kept (used by surviving unit test line 30); `.qa-chip__text`, `.qa-overlay`, `.qa-overlay__sheet`, `qa_show_question`, `qa_hide_question`, `ignore`, `@qa_show_question` all removed together in Tasks 2-3 with matching test deletions — no dangling reference.
