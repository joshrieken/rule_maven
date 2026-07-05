# Admin "All Questions" sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins, while viewing a game's Q&A sidebar, see every question asked about that game by any user (not just their own), search by asker, and open any of them inline with full existing admin capability.

**Architecture:** Reuse the existing `Games.grouped_questions/2` → `build_thread_summaries/1` → sidebar-render pipeline in `RuleMavenWeb.GameLive.Show` (`lib/rule_maven_web/live/game_live/show.ex`) unchanged in shape. Two small context-layer changes (uncap the query, preload `:user`) plus admin-aware options at the four existing call sites give the sidebar the full cross-user list for free — `switch_thread`/`active_thread_id` selection and the inline conversation view already operate generically over whatever is in `threads`/`grouped`, with no ownership filtering, so opening any user's question with full admin controls requires no new code path. The remaining work is: tag each row with its asker, extend the existing in-memory search filter to match asker name too, and stop excluding refused rows from the time groups for admins (since the "Not Covered" section that used to house them is redundant once all statuses are visible).

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, ExUnit + Phoenix.LiveViewTest.

## Global Constraints

- Admin-only: gated by `socket.assigns.is_admin` (`RuleMaven.Users.can?(current_user, :admin)`), already assigned in `mount/3` (show.ex:14). Non-admin behavior must be pixel-for-pixel unchanged.
- No pagination/cap on the admin "All Questions" load — per spec, accepted tradeoff, revisit later if perf becomes an issue.
- No new authorization checks needed for actions (delete/verify/visibility toggle) — those are already admin-gated per-action independent of whose question is open.

---

## File Structure

- Modify: `lib/rule_maven/games.ex` — `recent_questions/3` (games.ex:2019), `grouped_questions/2` (games.ex:1685)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — `do_handle_params/3` (~142), `build_thread_summaries/1` (~293), three more `grouped_questions`/`build_thread_summaries` call sites (~848-849, ~989-991, ~1083-1085), sidebar template (~1884-1970), `thread_sidebar_item/1` component (~3064-3099)
- Test: `test/rule_maven/games_test.exs` — new cases in the existing `"grouped questions"` describe block
- Test: new file `test/rule_maven_web/live/game_live_admin_all_questions_test.exs`

---

### Task 1: Uncap and preload the question query in `Games`

**Files:**
- Modify: `lib/rule_maven/games.ex:2019-2037` (`recent_questions/3`)
- Modify: `lib/rule_maven/games.ex:1685-1709` (`grouped_questions/2`)
- Test: `test/rule_maven/games_test.exs` (new cases in `describe "grouped questions"`, ~line 185)

**Interfaces:**
- Produces: `Games.grouped_questions(game, opts)` now accepts an additional `opts[:limit]` key (default `200`, `nil` means unlimited). `opts[:user_id]` behavior is unchanged (nil/omitted = no user filter, i.e. every user's questions for the game). Each returned `QuestionLog` struct now has `:user` preloaded.

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/games_test.exs`, inside the existing `describe "grouped questions"` block (after the setup at line 197, alongside the other tests):

```elixir
    test "grouped_questions/2 returns every user's questions when no user_id filter is given",
         %{game: game, user: user} do
      other =
        Repo.insert!(%RuleMaven.Users.User{
          username: "test_grouped_other",
          email: "test_grouped_other@test.com",
          password_hash: "x"
        })

      log_question!(game.id, user.id, "Mine", "Mine answer")
      log_question!(game.id, other.id, "Theirs", "Theirs answer")

      grouped = Games.grouped_questions(game)
      questions = Enum.map(grouped, & &1.primary.question)

      assert "Mine" in questions
      assert "Theirs" in questions
    end

    test "grouped_questions/2 preloads :user on the primary row", %{game: game, user: user} do
      log_question!(game.id, user.id, "Who asked?", "Someone")

      grouped = Games.grouped_questions(game)
      assert hd(grouped).primary.user.id == user.id
      assert hd(grouped).primary.user.username == user.username
    end

    test "grouped_questions/2 with limit: nil does not cap results", %{game: game, user: user} do
      for i <- 1..250 do
        log_question!(game.id, user.id, "Q#{i}", "A#{i}")
      end

      grouped = Games.grouped_questions(game, limit: nil)
      assert length(grouped) == 250
    end

    test "grouped_questions/2 default limit still caps at 200", %{game: game, user: user} do
      for i <- 1..205 do
        log_question!(game.id, user.id, "Cap Q#{i}", "A#{i}")
      end

      grouped = Games.grouped_questions(game, user_id: user.id)
      assert length(grouped) == 200
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/games_test.exs --only line:206` — actually run the whole describe block:
`mix test test/rule_maven/games_test.exs:199`

Expected: the new "every user's questions" and "preloads :user" tests pass already by coincidence (current code has no cap issue there) but the "preloads :user" test FAILS with something like `** (KeyError) key :user not found` or `Ecto.Association.NotLoaded` mismatch, and "limit: nil does not cap" FAILS because `grouped_questions/2` ignores `opts[:limit]` and always uses 200 — `length(grouped) == 250` fails (actual 200).

- [ ] **Step 3: Implement**

Replace `lib/rule_maven/games.ex:2019-2037`:

```elixir
  def recent_questions(%Game{} = game, limit \\ 20, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    base =
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        order_by: [desc: q.inserted_at],
        preload: [:user]

    base = if limit, do: from(q in base, limit: ^limit), else: base

    query =
      if user_id do
        from q in base,
          where: q.user_id == ^user_id or q.visibility == "community"
      else
        base
      end

    Repo.all(query)
  end
```

Replace `lib/rule_maven/games.ex:1685-1686` (the first two lines of `grouped_questions/2`):

```elixir
  def grouped_questions(%Game{} = game, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    all = recent_questions(game, limit, opts)
```

(leave the rest of the function — the `Enum.group_by`/sort pipeline — untouched).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/games_test.exs:199`
Expected: PASS (all cases in the `"grouped questions"` describe block, including the 4 new ones).

- [ ] **Step 5: Run the full games test file to check for regressions**

Run: `mix test test/rule_maven/games_test.exs`
Expected: PASS — no other test in this file depends on `recent_questions`'s previous unconditional `limit:` clause or the absence of a `:user` preload.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_test.exs
git commit -m "feat: uncap + preload user on grouped_questions for admin all-questions view"
```

---

### Task 2: Wire admin-aware options and asker labels into `GameLive.Show`

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:142-143` (initial mount/params load)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:293-316` (`build_thread_summaries/1`)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:848-849` (delete handler)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:989-991` (verify handler)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:1083-1085` (visibility toggle handler)
- Test: `test/rule_maven_web/live/game_live_admin_all_questions_test.exs` (new file)

**Interfaces:**
- Consumes: `Games.grouped_questions/2` from Task 1 (accepts `opts[:limit]`, `opts[:user_id]`).
- Produces: `question_group_opts/1` (new private fn, `socket -> keyword list`), `build_thread_summaries/2` (signature change from arity 1 — every caller must pass `current_user_id` now), each thread map in `@threads` now has an `:asker` key (string: `"You"`, the asker's `username`, or `"Unknown"`).

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/game_live_admin_all_questions_test.exs`:

```elixir
defmodule RuleMavenWeb.GameLiveAdminAllQuestionsTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  test "admin sees other users' questions in the sidebar, tagged with their name", %{conn: conn} do
    admin = create_user("aq_admin", %{role: "admin"})
    other = create_user("aq_other")
    game = published_game_fixture(%{name: "All Questions Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "How do I score?",
        answer: "Count the points.",
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "How do I score?"
    assert html =~ other.username
  end

  test "non-admin does not see other users' questions in the sidebar", %{conn: conn} do
    viewer = create_user("aq_viewer")
    other = create_user("aq_other2")
    game = published_game_fixture(%{name: "All Questions Game 2"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Secret other question",
        answer: "Secret answer.",
        visibility: "private"
      })

    conn = login(conn, viewer)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ "Secret other question"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live_admin_all_questions_test.exs`
Expected: FAIL on the first test — admin's sidebar shows only their own questions today, so `html =~ "How do I score?"` fails (question never rendered), and there is no asker-name rendering at all yet.

- [ ] **Step 3: Implement — helper functions**

Insert after `build_thread_summaries/1` ends, i.e. after `lib/rule_maven_web/live/game_live/show.ex:316` (right after the closing of the `Enum.sort_by` call), replacing the whole function:

```elixir
  defp build_thread_summaries(grouped, current_user_id) do
    recent = DateTime.utc_now() |> DateTime.add(-120, :second)

    grouped
    |> Enum.map(fn g ->
      pending? =
        g.primary.answer == "Thinking..." &&
          not is_nil(g.primary.inserted_at) &&
          DateTime.compare(g.primary.inserted_at, recent) == :gt

      %{
        id: g.primary.id,
        question: QuestionLog.display_question(g.primary),
        answer: g.primary.answer,
        pending: pending?,
        refused: g.primary.refused,
        favorited: g.primary.favorited,
        inserted_at: g.primary.inserted_at,
        asker: asker_label(g.primary, current_user_id)
      }
    end)
    |> Enum.sort_by(fn t -> {if(t.favorited, do: 0, else: 1), t.inserted_at} end, fn
      {fa, ta}, {fb, tb} -> fa < fb || (fa == fb && DateTime.compare(ta, tb) == :gt)
    end)
  end

  defp asker_label(%{user_id: uid}, uid), do: "You"
  defp asker_label(%{user: %RuleMaven.Users.User{username: username}}, _uid)
       when is_binary(username),
       do: username

  defp asker_label(_question, _current_user_id), do: "Unknown"

  defp question_group_opts(socket) do
    if socket.assigns.is_admin do
      [limit: nil]
    else
      [user_id: socket.assigns.current_user.id]
    end
  end
```

- [ ] **Step 4: Implement — update the four call sites**

`lib/rule_maven_web/live/game_live/show.ex:142-143`:

```elixir
    grouped = Games.grouped_questions(game, question_group_opts(socket))
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)
```

`lib/rule_maven_web/live/game_live/show.ex:848-849` (inside `confirm_delete_question`):

```elixir
    grouped = Games.grouped_questions(game, question_group_opts(socket))
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)
```

`lib/rule_maven_web/live/game_live/show.ex:989-991` (inside `verify_question`):

```elixir
    grouped = Games.grouped_questions(game, question_group_opts(socket))
    conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
    threads = build_thread_summaries(grouped, socket.assigns.current_user.id)
```

`lib/rule_maven_web/live/game_live/show.ex:1083-1085` (inside `do_toggle_question_visibility`):

```elixir
        grouped = Games.grouped_questions(game, question_group_opts(socket))
        conversation = build_conversation_for_thread(grouped, socket.assigns.active_thread_id)
        threads = build_thread_summaries(grouped, socket.assigns.current_user.id)
```

- [ ] **Step 5: Run test — still expect a specific failure**

Run: `mix test test/rule_maven_web/live/game_live_admin_all_questions_test.exs`
Expected: the "admin sees other users' questions" test now gets the question into `@threads`, but `assert html =~ other.username` still FAILS — the template doesn't render `:asker` anywhere yet. That's Task 3's job. The "non-admin" test should already PASS at this point (non-admin path is unaffected — `question_group_opts/1` returns `[user_id: ...]` same as before).

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live_admin_all_questions_test.exs
git commit -m "feat: admin-aware question grouping + asker labels in Show liveview"
```

---

### Task 3: Render asker tags, extend search, fold "Not Covered" for admins

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:1884-1970` (sidebar template body)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:1254-1273` (add `matches_search?/2` near `group_threads_by_time/1`)
- Modify: `lib/rule_maven_web/live/game_live/show.ex:3064-3099` (`thread_sidebar_item/1` component)
- Test: `test/rule_maven_web/live/game_live_admin_all_questions_test.exs` (extend from Task 2)

**Interfaces:**
- Consumes: `t.asker` (from Task 2's `build_thread_summaries/2`), `@is_admin` (existing assign).
- Produces: `matches_search?/2` (private fn, `(thread_map, String.t()) -> boolean`), `thread_sidebar_item/1` gains a `show_asker` attr.

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven_web/live/game_live_admin_all_questions_test.exs` (same module as Task 2):

```elixir
  test "admin can search the sidebar by asker name", %{conn: conn} do
    admin = create_user("aq_admin2", %{role: "admin"})
    other = create_user("aq_searchable")
    game = published_game_fixture(%{name: "Search By Asker Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Totally unrelated text",
        answer: "Some answer.",
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = view |> element("form[phx-change='search']") |> render_change(%{"query" => other.username})

    assert html =~ "Totally unrelated text"
  end

  test "admin does not see a separate Not Covered section (refused folded into All Questions)",
       %{conn: conn} do
    admin = create_user("aq_admin3", %{role: "admin"})
    game = published_game_fixture(%{name: "Refused Fold Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: admin.id,
        question: "Not in the rulebook",
        answer: "Not covered.",
        refused: true,
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Not in the rulebook"
    refute html =~ "Not Covered"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven_web/live/game_live_admin_all_questions_test.exs`
Expected: "search by asker name" FAILS (search only matches question/answer text, not asker name — no rows match `other.username` as a query string). "Not Covered folded" FAILS on `refute html =~ "Not Covered"` (the refused question is currently excluded from the time groups and shown only under the always-rendered-when-nonzero "Not Covered" heading, which is still present).

- [ ] **Step 3: Implement — `matches_search?/2` helper**

Insert directly above `group_threads_by_time/1` at `lib/rule_maven_web/live/game_live/show.ex:1254`:

```elixir
  defp matches_search?(_t, ""), do: true

  defp matches_search?(t, query) do
    q = String.downcase(query)

    String.contains?(String.downcase(t.question), q) ||
      (is_binary(t[:asker]) && String.contains?(String.downcase(t.asker), q))
  end

  defp group_threads_by_time(threads) do
```

(the `defp group_threads_by_time(threads) do` line already exists — this step only adds the new function above it, leaving `group_threads_by_time/1`'s body untouched).

- [ ] **Step 4: Implement — template changes**

Replace `lib/rule_maven_web/live/game_live/show.ex:1884-1922`:

```elixir
          <!-- Thread list grouped by time -->
          <% community_ids = MapSet.new(@community_questions, & &1.id) %>
          <% answered =
            if @is_admin do
              Enum.reject(@threads, fn t -> MapSet.member?(community_ids, t.id) end)
            else
              Enum.reject(@threads, fn t ->
                t.refused || MapSet.member?(community_ids, t.id)
              end)
            end %>
          <% refused = if @is_admin, do: [], else: Enum.filter(@threads, & &1.refused) %>
          <% refused_count = length(refused) %>
          <%!-- Favorites get their own section above the time groups (not just
                floated within Today), so an old favorited question stays
                pinned even once it's aged out of "Today". --%>
          <% {favorited_threads, unfavorited} = Enum.split_with(answered, & &1.favorited) %>
          <% favorited_threads = Enum.filter(favorited_threads, &matches_search?(&1, @search_query)) %>
          <% groups = group_threads_by_time(unfavorited) %>
          <% refused_groups = group_threads_by_time(refused) %>

          <%= if favorited_threads != [] do %>
            <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
              Favorites
            </div>
            <.thread_sidebar_item
              :for={t <- favorited_threads}
              t={t}
              active_thread_id={@active_thread_id}
              show_asker={@is_admin}
            />
          <% end %>

          <%= for {label, key} <- [{"Today", :today}, {"Last 7 Days", :week}, {"Older", :older}] do %>
            <% items = Map.get(groups, key, []) |> Enum.filter(&matches_search?(&1, @search_query)) %>
            <%= if items != [] do %>
              <div style="padding:0.3rem 0.75rem 0.1rem;font-size:0.6rem;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em">
                {label}
              </div>
              <.thread_sidebar_item
                :for={t <- items}
                t={t}
                active_thread_id={@active_thread_id}
                show_asker={@is_admin}
              />
            <% end %>
          <% end %>
```

(the rest of the sidebar — the "Refused toggle" block at what was lines 1924-1962, the "No matching questions" block, and the "No questions yet" block — is unchanged code, just renumbered; it still works because `refused_count` is now always `0` for admins, so the whole "Refused toggle" `<%= if refused_count > 0 do %>` block simply never renders for them — no `:if={!@is_admin}` needed).

Update the "No matching questions" check (now a few lines further down, originally 1964-1966) to use the same helper — replace:

```elixir
          <%= if @search_query != "" &&
               Enum.all?(@threads, fn t -> @search_query == "" || not String.contains?(String.downcase(t.question), String.downcase(@search_query)) end) &&
               Enum.all?(@community_questions, fn q -> @search_query == "" || not String.contains?(String.downcase(q.question), String.downcase(@search_query)) end) do %>
```

with:

```elixir
          <%= if @search_query != "" &&
               Enum.all?(@threads, fn t -> not matches_search?(t, @search_query) end) &&
               Enum.all?(@community_questions, fn q -> @search_query == "" || not String.contains?(String.downcase(q.question), String.downcase(@search_query)) end) do %>
```

- [ ] **Step 5: Implement — `thread_sidebar_item/1` asker badge**

Replace `lib/rule_maven_web/live/game_live/show.ex:3064-3099`:

```elixir
  # One sidebar row: shared by the Favorites section and each time group
  # (Today/Last 7 Days/Older) so the two render identically.
  attr :t, :map, required: true
  attr :active_thread_id, :any, required: true
  attr :show_asker, :boolean, default: false

  defp thread_sidebar_item(assigns) do
    ~H"""
    <%!-- id carries the favorited flag: a toggle moves this row into a
          different section (Favorites <-> the time groups), and folding
          favorited into the id forces LiveView to unmount/remount the node
          instead of relocating the existing one, so the CSS entrance
          animation (.sidebar-item) fires the same way in both directions. --%>
    <button
      id={"thread-#{@t.id}-#{@t.favorited}"}
      type="button"
      class="sidebar-item"
      phx-click="switch_thread"
      phx-value-id={@t.id}
      style={"display:block;text-align:left;border:none;cursor:pointer;padding:0.22rem 0.75rem;font-size:0.73rem;line-height:1.35;border-left:2px solid #{if @active_thread_id == @t.id, do: "var(--accent)", else: "transparent"};width:100%;color:var(--text)"}
    >
      <div style="display:flex;align-items:baseline;gap:0.2rem">
        <span :if={@t.favorited} style="color:#e05c2a;font-size:0.55rem;flex-shrink:0">♥</span>
        <span
          :if={@t.pending}
          class="animate-pulse"
          style="color:var(--accent-ink,var(--accent));font-size:0.45rem;flex-shrink:0"
        >●</span>
        <span
          :if={!@t.pending && is_binary(@t.answer) && String.starts_with?(@t.answer, "⚠️")}
          style="color:var(--red,#e53e3e);font-size:0.55rem;flex-shrink:0"
          title="Failed"
        >⚠</span>
        <span
          :if={@t.refused}
          style="color:var(--text-muted);font-size:0.55rem;flex-shrink:0"
          title="Not covered by the rules"
        >🚫</span>
        <span style="word-break:break-word;white-space:normal">
          <span
            :if={@show_asker}
            style="color:var(--text-muted);font-weight:600;font-size:0.62rem;margin-right:0.25rem"
          >{@t.asker}:</span>{@t.question}
        </span>
      </div>
    </button>
    """
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/rule_maven_web/live/game_live_admin_all_questions_test.exs`
Expected: all 4 tests PASS.

- [ ] **Step 7: Run the full Show liveview surface + games tests for regressions**

Run: `mix test test/rule_maven_web/live/ test/rule_maven/games_test.exs`
Expected: PASS. In particular, existing non-admin behavior (Not Covered section, Favorites, search) is untouched by these branches since `@is_admin` is `false` for those flows.

- [ ] **Step 8: Manual verification**

Per the "verify major only" convention, this is a user-facing sidebar behavior change — start the app and confirm in browser:
1. Log in as a non-admin, ask a question, confirm sidebar unchanged (My Questions time groups, Not Covered still present if any refused).
2. Log in as an admin on a game with questions from multiple users, confirm: all questions appear tagged with asker name (or "You"), refused ones show the 🚫 marker inline (no separate Not Covered heading), search box filters by both question text and asker name, and clicking another user's question opens it inline with full admin controls (delete/visibility/verify/version-history) available.

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live_admin_all_questions_test.exs
git commit -m "feat: render asker tags, search-by-asker, and fold Not Covered for admins"
```

---

## Self-Review Notes

- **Spec coverage:** admin-only gating (Task 1-3, `@is_admin`), "My Questions" data source becomes all-users (Task 1-2), "Not Covered" folded away (Task 3), asker tagging incl. "You" (Task 2), search extended to asker (Task 3), no cap (Task 1), inline full-capability click-through (already generic, verified in Task 2/3 tests + Step 8 manual check) — all covered.
- **Placeholder scan:** none: every step has literal code.
- **Type consistency:** `build_thread_summaries/2` signature (grouped, current_user_id) used identically at all 4 call sites in Task 2; `t.asker` key introduced in Task 2, consumed in Task 3's `matches_search?/2` and `thread_sidebar_item/1` — names match throughout.
