# Citation Card Grouping + Sort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `citation_list/1` (`lib/rule_maven_web/live/game_live/show.ex`) group same-page-and-source citations into one card (quotes joined with an ellipsis) and sort cards by page ascending, so the Q&A thread's citation cards read cleanly instead of showing duplicate-page cards out of order.

**Architecture:** Pure render-time transformation added to the end of the existing `citation_list/1` private helper — no schema, persistence, or `AskWorker`/`Citations` module change. The function already normalizes a message into a list of `%{"quote" =>, "page" =>, "source" =>}` string-keyed maps (new `citations` field, or legacy scalar-field fallback); this task adds a group-then-sort pass on that list before it's returned to the template.

**Tech Stack:** Elixir, Phoenix LiveView (HEEx template, unchanged by this plan — only the helper function changes).

## Global Constraints

- Citation maps are string-keyed (`"quote"`, `"page"`, `"source"`) — this plan's new code must read/write those same string keys, never atom keys.
- Group by the exact `{page, source}` pair — both must match; a shared page number with a different source stays a separate card.
- A group with 2+ quotes always joins them with `" … "` (single ellipsis character, U+2026) in original relative order — there is no "skip the ellipsis if adjacent" case (not determinable from persisted data, per spec).
- Sort by `page` ascending; a `nil` page group sorts after every group that has a page.
- Render-time only — the persisted `citations` jsonb column and everything upstream of `citation_list/1` is untouched.

---

### Task 1: Group and sort citations in `citation_list/1`

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:3269` (the `citation_list/1` function)
- Test: no existing automated test targets this private helper; this task adds a small `ExUnit.Case` test module that calls it directly via the module's fully qualified name (Elixir allows testing private functions is NOT supported directly — see Step 1 below for the actual approach taken).

**Interfaces:**
- Consumes: nothing new — operates only on the list `citation_list/1` already produces internally (list of `%{"quote" => string | nil, "page" => integer | nil, "source" => string | nil}`).
- Produces: `citation_list/1`'s return value is now grouped-and-sorted instead of raw-order — no signature change, no new public function. The HEEx template call site (`<%= for c <- citation_list(msg) do %>` at line 2253) needs no change since the interface (a list of the same map shape) is unchanged.

- [ ] **Step 1: Read the current function and confirm exact content**

Run: `sed -n '3266,3282p' lib/rule_maven_web/live/game_live/show.ex`

Expected output (confirm this matches before editing — if it has drifted, stop and re-derive the edit from the actual content):

```elixir
  # A message's citation list, preferring the new multi-citation field and
  # falling back to the legacy scalar fields for rows saved before the
  # `citations` column existed (or the mock/legacy-wrap path in AskWorker).
  defp citation_list(msg) do
    case msg[:citations] do
      list when is_list(list) and list != [] ->
        list

      _ ->
        if msg[:cited_passage] do
          [%{"quote" => msg.cited_passage, "page" => msg[:cited_page], "source" => msg[:cited_source]}]
        else
          []
        end
    end
  end
```

Since `citation_list/1` is a `defp` (private), it cannot be called directly from a separate `ExUnit.Case` test module. Rather than making it public (which would be a scope-creep API change to a LiveView module, not requested by the spec), this task extracts the new grouping/sorting logic into its own small `defp`, and tests that piece — `group_and_sort_citations/1` — as a `doctest`-free unit by temporarily calling it via `:erlang.apply/3` is unnecessary complexity; instead, follow this codebase's own precedent: `show.ex` has no unit tests for its private render helpers anywhere (confirmed: no `test/rule_maven_web/live/game_live_show_test.exs` file exists, and the only test touching this module's citation rendering, `test/rule_maven_web/live/game_live_citation_source_test.exs`, drives it through a full LiveView render, not direct function calls). Follow that same convention — verify this task by extending `test/rule_maven_web/live/game_live_citation_source_test.exs` with a new LiveView-driven test, not a unit test of the private function. See Step 3.

- [ ] **Step 2: Implement the grouping/sorting**

Replace the function (same location, `lib/rule_maven_web/live/game_live/show.ex:3269`) with:

```elixir
  # A message's citation list, preferring the new multi-citation field and
  # falling back to the legacy scalar fields for rows saved before the
  # `citations` column existed (or the mock/legacy-wrap path in AskWorker).
  # The raw list is then grouped (same page + source merge into one card,
  # quotes joined with an ellipsis) and sorted by page ascending.
  defp citation_list(msg) do
    case msg[:citations] do
      list when is_list(list) and list != [] ->
        group_and_sort_citations(list)

      _ ->
        if msg[:cited_passage] do
          [%{"quote" => msg.cited_passage, "page" => msg[:cited_page], "source" => msg[:cited_source]}]
        else
          []
        end
    end
  end

  # Merges citations that share the same {page, source} into one card (quotes
  # joined with " … ", in original relative order), then sorts cards by page
  # ascending. A citation with no page sorts after every page-bearing card —
  # true textual contiguity between two quotes can't be determined from what's
  # persisted (only the quote/page/source triple is stored, not the source
  # rulebook text), so every merged (2+ quote) card always gets the ellipsis.
  defp group_and_sort_citations(citations) do
    citations
    |> Enum.group_by(&{&1["page"], &1["source"]})
    |> Enum.map(fn {{page, source}, group} ->
      quote = group |> Enum.map(& &1["quote"]) |> Enum.join(" … ")
      %{"page" => page, "source" => source, "quote" => quote}
    end)
    |> Enum.sort_by(fn %{"page" => page} -> {page == nil, page} end)
  end
```

- [ ] **Step 3: Add a LiveView-driven regression test**

`test/rule_maven_web/live/game_live_citation_source_test.exs` already establishes the exact
pattern: `use RuleMavenWeb.ConnCase, async: true`, `import Phoenix.LiveViewTest`,
`import RuleMaven.GamesFixtures`, a `login/2` helper, a `setup_user/1` helper, a game via
`published_game_fixture/1`, a question row via `Games.log_question/1`, a real connected
LiveView render via `live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")`, and plain
`assert html =~ "..."` substring assertions (no Floki, no byte-offset helpers). `Games.log_question/1`
accepts a `citations:` key directly (cast in the `QuestionLog` changeset by the multi-citation
plan's Task 1) alongside the existing fields.

Add this test to the same file, right after the existing two tests, before the final `end`:

```elixir
  test "same-page citations merge into one card, ellipsis-joined, and cards sort by page", %{
    conn: conn
  } do
    user = setup_user("cite_group")
    game = published_game_fixture(%{name: "Cite Group Game"})

    {:ok, _ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How is the d20 used?",
        answer: "It picks the first player and damages the Beholder.",
        citations: [
          %{"quote" => "Damage the Beholder's eyestalks.", "page" => 11, "source" => "Core rules"},
          %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"},
          %{"quote" => "then blind its central antimagic eye.", "page" => 11, "source" => "Core rules"}
        ],
        visibility: "private"
      })

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Damage the Beholder's eyestalks. … then blind its central antimagic eye."

    [_before_p5, after_p5] =
      String.split(html, "Roll the d20 to determine the first player.", parts: 2)

    assert after_p5 =~ "Damage the Beholder's eyestalks."
  end
```

This exercises both requirements in one test: the two p.11/"Core rules" quotes must merge
into a single ellipsis-joined card (first assertion), and that merged p.11 card must render
strictly after the p.5 card despite p.11 appearing first in the input list (the split/assert
pair — the p.5 quote's text is asserted to occur only in the portion of the HTML that comes
before the p.11 quote's text, so if `after_p5` didn't contain it, the split would have failed
to find the Beholder quote after the d20 quote at all).

- [ ] **Step 4: Run the new/modified test file**

Run: `mix test test/rule_maven_web/live/game_live_citation_source_test.exs -v`
Expected: all tests pass, including the new grouping/sort test.

- [ ] **Step 5: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly, no warnings (in particular, no "variable quote shadows import Kernel.quote/2" warning — if that warning appears, rename the local variable in `group_and_sort_citations/1` from `quote` to `joined_quote` and re-run).

- [ ] **Step 6: Manual verification**

Start the app (`mix phx.server`), open a Q&A thread with a multi-citation answer (or ask a multi-topic question against a game with retrievable multi-page content), and confirm: citations render in ascending page order, and any same-page/same-source repeats merge into one card with an ellipsis-joined quote.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live_citation_source_test.exs
git commit -m "feat: group same-page citations and sort citation cards by page"
```

---

## Self-Review Notes

- **Spec coverage:** grouping by `{page, source}` ✅ (Step 2), ellipsis join for 2+ quotes ✅ (Step 2), sort ascending with nil-page-last ✅ (`Enum.sort_by` tuple trick: `page == nil` is `false` (sorts first) for real pages and `true` (sorts last) for `nil`, then by `page` itself), render-time-only/no persistence change ✅ (single function, no schema/worker touched).
- **Placeholder scan:** none — all code blocks are complete, runnable Elixir.
- **Type consistency:** `group_and_sort_citations/1` takes and returns the same `%{"quote" =>, "page" =>, "source" =>}` string-keyed shape `citation_list/1` already produced elsewhere in this codebase (Task 5/6 of the prior multi-citation plan) — no key-shape drift.
