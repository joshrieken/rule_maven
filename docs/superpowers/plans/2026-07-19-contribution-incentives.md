# Contribution Incentives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the reward layer on top of the merged Coverage Engine — a shared community coverage meter with an actionable gap to-do list + contribution credit, and a personal per-game title driven by the pages you've asked-about-or-read.

**Architecture:** A new per-user page-exposure table `user_page_coverages` mirrors the community `document_page_coverages`. `RuleMaven.Coverage` gains personal-track reads (`record_personal`, `personal_for_game`, `title_for`, `gaps_enriched`, `contribution_credit`), reusing the existing `(document_id, page)` extraction (DRY). One instrumentation point in `game_live/show.ex` stamps personal coverage when a grounded answer becomes visible. UI: a sidebar coverage meter + gap panel, and a per-game title beside the existing mastery HUD.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/Postgres, ExUnit.

## Global Constraints

- Zero warnings, zero failing tests — never leave a warning or red test as "pre-existing" (HARD RULE). `mix compile --warnings-as-errors` clean.
- Run only the relevant test files; tee to `./tmp/<name>.log`; do not run the full suite twice.
- Never delete `llm_logs` rows in test cleanup.
- Repo test style: fixture helpers (`RuleMaven.GamesFixtures.game_fixture/1`, direct `Repo.insert`), NOT ExMachina `insert/1`. Mirror `test/rule_maven/coverage_test.exs`.
- A global `~/.gitignore` has a bare `coverage/` pattern; `.gitignore` in-repo already negates `lib/rule_maven/coverage/`. Confirm new files under that path are tracked by `git status` before committing.
- Personal denominator MUST equal `for_game/1`'s denominator (published docs across `[game_id | expansion_game_ids]`) so personal and community bars are comparable.
- nil `page_count` ⇒ `pct: nil`; never divide by nil/zero.
- All coverage reads are additive: any error ⇒ caller renders normally, never a gate.
- Mobile-first hard rule: verify every UI change at 390px.
- `/help` + tours upkeep for user-facing changes (standing rule).
- Commit after each task. Trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `priv/repo/migrations/<ts>_create_user_page_coverages.exs` — new table.
- `lib/rule_maven/coverage/user_page_coverage.ex` — Ecto schema.
- `lib/rule_maven/coverage.ex` — extend context: refactor shared pair extraction, add `record_personal/2`, `personal_for_game/2`, `title_for/2`, `gaps_enriched/1`, `contribution_credit/2`.
- `lib/rule_maven_web/live/game_live/show.ex` — instrumentation helper + call sites; sidebar meter assigns.
- `lib/rule_maven_web/live/game_live/coverage_panel.ex` — new function component (community meter + gap panel).
- `lib/rule_maven_web/live/game_live/sub_bar.ex` — personal title beside `mastery_hud`.
- Tests: `test/rule_maven/coverage_test.exs` (extend), `test/rule_maven/coverage_personal_test.exs` (new, personal-track units), `test/rule_maven_web/live/game_live/coverage_incentives_test.exs` (instrumentation + render).

---

### Task 1: `user_page_coverages` table + schema

**Files:**
- Create: `priv/repo/migrations/<ts>_create_user_page_coverages.exs`
- Create: `lib/rule_maven/coverage/user_page_coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Produces: `RuleMaven.Coverage.UserPageCoverage` schema over `user_page_coverages`, fields `user_id`, `document_id`, `page`; unique index `(user_id, document_id, page)`.

- [ ] **Step 1: Generate + write the migration** (`mix ecto.gen.migration create_user_page_coverages`, then body:)

```elixir
defmodule RuleMaven.Repo.Migrations.CreateUserPageCoverages do
  use Ecto.Migration

  def change do
    create table(:user_page_coverages) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :page, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_page_coverages, [:user_id, :document_id, :page])
    create index(:user_page_coverages, [:user_id, :document_id])
  end
end
```

- [ ] **Step 2: Write the schema**

```elixir
defmodule RuleMaven.Coverage.UserPageCoverage do
  use Ecto.Schema

  schema "user_page_coverages" do
    field :page, :integer
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document

    timestamps(type: :utc_datetime)
  end
end
```

- [ ] **Step 3: Write failing test** (`test/rule_maven/coverage_personal_test.exs`)

```elixir
defmodule RuleMaven.CoveragePersonalTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures
  alias RuleMaven.Coverage
  alias RuleMaven.Coverage.UserPageCoverage
  alias RuleMaven.Repo

  # Mirror the doc/user setup style already in test/rule_maven/coverage_test.exs.
  defp published_doc(game, attrs \\ %{}) do
    {:ok, doc} =
      %RuleMaven.Games.Document{game_id: game.id}
      |> RuleMaven.Games.Document.changeset(
        Map.merge(%{label: "Rulebook", status: "published", page_count: 10}, attrs)
      )
      |> Repo.insert()

    doc
  end

  test "user page coverage enforces (user_id, document_id, page) uniqueness" do
    game = game_fixture()
    doc = published_doc(game)
    user = RuleMaven.AccountsFixtures.user_fixture()

    Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 3})
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 3})
    end
  end
end
```

(Confirm the real user-fixture module name before running — grep `def user_fixture` under `test/support`. If it differs from `RuleMaven.AccountsFixtures`, use the actual one. Confirm `Document.changeset/2` accepts `label/status/page_count` — Task-1 of the coverage engine already used this pattern.)

- [ ] **Step 4: Migrate + run test**
  Run: `mix ecto.migrate && mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task1.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations lib/rule_maven/coverage/user_page_coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): user_page_coverages table + schema"
```

---

### Task 2: `record_personal/2` (+ DRY refactor of pair extraction)

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Consumes: existing private `covered_pair/2`, `page_count_map/1` in `coverage.ex`.
- Produces:
  - private `distinct_covered_pairs(citations) :: [{integer, integer}]` — shared extraction (flat_map `covered_pair` + `uniq`).
  - `record_personal(user_id :: integer, citations :: [map]) :: {:ok, non_neg_integer}` — idempotent upsert into `user_page_coverages`. `user_id` nil ⇒ `{:ok, 0}`.

- [ ] **Step 1: Write failing test** (append to `coverage_personal_test.exs`)

```elixir
describe "record_personal/2" do
  test "upserts distinct pages for a user, idempotent, clamps, skips unknown doc" do
    game = game_fixture()
    doc = published_doc(game, %{page_count: 8})
    user = RuleMaven.AccountsFixtures.user_fixture()

    citations = [
      %{"page" => 3, "document_id" => doc.id},
      %{"page" => 3, "document_id" => doc.id},        # dup
      %{"page" => 99, "document_id" => doc.id},       # beyond page_count -> skip
      %{"page" => 5, "document_id" => 999_999},       # unknown doc -> skip (no FK crash)
      %{"page" => 4, "document_id" => nil}            # no doc -> skip
    ]

    assert {:ok, 1} = Coverage.record_personal(user.id, citations)   # page 3 only
    assert {:ok, 0} = Coverage.record_personal(user.id, citations)   # idempotent
    assert Repo.aggregate(
             from(u in UserPageCoverage, where: u.user_id == ^user.id),
             :count
           ) == 1
  end

  test "nil user_id records nothing" do
    game = game_fixture()
    doc = published_doc(game)
    assert {:ok, 0} = Coverage.record_personal(nil, [%{"page" => 1, "document_id" => doc.id}])
  end
end
```

(Add `import Ecto.Query` and alias `UserPageCoverage` at the top of the test module if not already present.)

- [ ] **Step 2: Run test, verify fails**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task2.log`
  Expected: FAIL — `record_personal/2` undefined.

- [ ] **Step 3: Refactor + implement** in `coverage.ex`.
  First extract the shared extraction and reuse it in `record_citations/1`:

```elixir
  # Shared: distinct valid (document_id, page) pairs from a citation list,
  # clamped to page_count, unknown documents skipped. Used by both the
  # community (record_citations) and personal (record_personal) write paths.
  defp distinct_covered_pairs(citations) when is_list(citations) do
    page_counts = page_count_map(citations)

    citations
    |> Enum.flat_map(&covered_pair(&1, page_counts))
    |> Enum.uniq()
  end

  defp distinct_covered_pairs(_), do: []
```

  Change `record_citations/1` to use it (replace the `page_counts`/`flat_map`/`uniq` lines):

```elixir
  def record_citations(%{citations: citations} = ql) when is_list(citations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> distinct_covered_pairs()
      |> Enum.map(fn {doc_id, page} ->
        %{
          document_id: doc_id,
          page: page,
          first_covered_by_user_id: Map.get(ql, :user_id),
          first_question_log_id: Map.get(ql, :id),
          first_covered_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(PageCoverage, rows, on_conflict: :nothing, conflict_target: [:document_id, :page])

    {:ok, count}
  end
```

  Then add `record_personal/2`:

```elixir
  alias RuleMaven.Coverage.UserPageCoverage

  @doc "Record a user's personal page exposure from a grounded answer's citations. Idempotent."
  @spec record_personal(integer() | nil, [map()]) :: {:ok, non_neg_integer()}
  def record_personal(user_id, citations) when is_integer(user_id) and is_list(citations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> distinct_covered_pairs()
      |> Enum.map(fn {doc_id, page} ->
        %{
          user_id: user_id,
          document_id: doc_id,
          page: page,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(UserPageCoverage, rows,
        on_conflict: :nothing,
        conflict_target: [:user_id, :document_id, :page]
      )

    {:ok, count}
  end

  def record_personal(_user_id, _citations), do: {:ok, 0}
```

- [ ] **Step 4: Run test + re-run the community test file** (refactor must not regress it)
  Run: `mix test test/rule_maven/coverage_personal_test.exs test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/incentives_task2.log`
  Expected: PASS (all community tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): record_personal + DRY pair extraction"
```

---

### Task 3: `personal_for_game/2`

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Consumes: existing `for_game/1`'s helpers `expansion_game_ids/1`, `summarize/2`, `pct/2` (already private in `coverage.ex`).
- Produces: `personal_for_game(user_id, game_id) :: %{covered, total, pct}` — user's covered pages across published docs of `[game_id | expansion_game_ids]`, same denominator as `for_game/1`.

- [ ] **Step 1: Write failing test**

```elixir
describe "personal_for_game/2" do
  test "personal pct uses the same denominator as for_game" do
    game = game_fixture()
    doc = published_doc(game, %{page_count: 4})
    user = RuleMaven.AccountsFixtures.user_fixture()

    Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 1})
    Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 2})

    assert %{total: 4, covered: 2, pct: pct} = Coverage.personal_for_game(user.id, game.id)
    assert_in_delta pct, 0.5, 0.001
    # denominator parity: community for_game over the same game reports total 4
    assert Coverage.for_game(game.id).total == 4
  end

  test "nil page_count -> nil pct" do
    game = game_fixture()
    _doc = published_doc(game, %{page_count: nil})
    user = RuleMaven.AccountsFixtures.user_fixture()
    assert %{pct: nil} = Coverage.personal_for_game(user.id, game.id)
  end
end
```

- [ ] **Step 2: Run, verify fails.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task3.log`
  Expected: FAIL — undefined.

- [ ] **Step 3: Implement** (append to `coverage.ex`)

```elixir
  @doc "A user's personal coverage rollup across the game's published docs + expansions."
  def personal_for_game(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{document_id: d.id, page_count: d.page_count}
      )

    doc_ids = Enum.map(docs, & &1.document_id)

    counts =
      Repo.all(
        from u in UserPageCoverage,
          where: u.user_id == ^user_id and u.document_id in ^doc_ids,
          group_by: u.document_id,
          select: {u.document_id, count(u.id)}
      )
      |> Map.new()

    summaries =
      Enum.map(docs, fn d -> summarize(d.page_count, Map.get(counts, d.document_id, 0)) end)

    total = summaries |> Enum.map(&(&1.page_count || 0)) |> Enum.sum()
    covered = summaries |> Enum.map(fn s -> if s.page_count, do: s.covered, else: 0 end) |> Enum.sum()
    %{covered: covered, total: total, pct: pct(covered, total)}
  end
```

(Note the `covered` sum excludes nil-page_count docs from the numerator — the same >100% guard applied to `for_game/1` in the coverage engine fix wave. `summarize/2` and `pct/2` already exist and cap per-doc covered at page_count.)

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task3.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): personal_for_game rollup"
```

---

### Task 4: `title_for/2`

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Consumes: `personal_for_game/2`, `for_game/1`, `UserPageCoverage`, `PageCoverage`, `Games.get_game/1`.
- Produces: `title_for(user_id, game_id) :: %{tier, label, pct, next_tier, pages_to_next}` where `tier ∈ {nil, :student, :scholar, :expert, :sage}`; `label` = `"<Game> <Tier>"` (nil tier ⇒ `label: nil`); `pct` = personal pct (or nil); `next_tier`/`pages_to_next` describe progress to the next tier (nil at Sage or when pct nil).

- [ ] **Step 1: Write failing test**

```elixir
describe "title_for/2" do
  setup do
    game = game_fixture(%{name: "Catan"})
    doc = published_doc(game, %{page_count: 4})
    user = RuleMaven.AccountsFixtures.user_fixture()
    %{game: game, doc: doc, user: user}
  end

  test "below 25% has no title", %{game: g, user: u} do
    assert %{tier: nil, label: nil} = Coverage.title_for(u.id, g.id)
  end

  test "25% -> Student, label carries game name", %{game: g, doc: d, user: u} do
    Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: 1})  # 1/4 = 25%
    assert %{tier: :student, label: "Catan Student", pct: pct} = Coverage.title_for(u.id, g.id)
    assert_in_delta pct, 0.25, 0.001
  end

  test "50% -> Scholar, 75% -> Expert", %{game: g, doc: d, user: u} do
    Enum.each(1..2, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))
    assert %{tier: :scholar} = Coverage.title_for(u.id, g.id)
    Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: 3})           # 3/4 = 75%
    assert %{tier: :expert} = Coverage.title_for(u.id, g.id)
  end

  test "Sage when personal set covers the whole community-covered set", %{game: g, doc: d, user: u} do
    # community grounded only pages 1 and 2 (2 of 4 pages)
    Enum.each(1..2, &Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: d.id, page: &1}))
    # user has personally covered both community pages (and no more)
    Enum.each(1..2, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))
    assert %{tier: :sage} = Coverage.title_for(u.id, g.id)
  end

  test "empty community set is not Sage", %{game: g, doc: d, user: u} do
    Enum.each(1..3, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))  # 75%
    assert %{tier: :expert} = Coverage.title_for(u.id, g.id)  # not sage: no community pages
  end
end
```

- [ ] **Step 2: Run, verify fails.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task4.log`
  Expected: FAIL — undefined.

- [ ] **Step 3: Implement** (append to `coverage.ex`)

```elixir
  @tier_order [:student, :scholar, :expert, :sage]
  @tier_names %{student: "Student", scholar: "Scholar", expert: "Expert", sage: "Sage"}

  @doc "A user's per-game title derived from personal coverage vs the community-covered set."
  def title_for(user_id, game_id) do
    personal = personal_for_game(user_id, game_id)
    sage? = sage?(user_id, game_id)
    tier = tier_for(personal.pct, sage?)

    game_name =
      case Games.get_game(game_id) do
        nil -> nil
        g -> g.name
      end

    %{
      tier: tier,
      label: label_for(tier, game_name),
      pct: personal.pct,
      next_tier: next_tier(tier),
      pages_to_next: pages_to_next(tier, personal)
    }
  end

  # Sage: the user's personal page set covers 100% of the community-covered set (non-empty).
  defp sage?(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    doc_ids =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    community =
      Repo.all(from p in PageCoverage, where: p.document_id in ^doc_ids, select: {p.document_id, p.page})
      |> MapSet.new()

    if MapSet.size(community) == 0 do
      false
    else
      personal =
        Repo.all(
          from u in UserPageCoverage,
            where: u.user_id == ^user_id and u.document_id in ^doc_ids,
            select: {u.document_id, u.page}
        )
        |> MapSet.new()

      MapSet.subset?(community, personal)
    end
  end

  defp tier_for(nil, _sage?), do: nil
  defp tier_for(_pct, true), do: :sage
  defp tier_for(pct, _sage?) when pct >= 0.75, do: :expert
  defp tier_for(pct, _sage?) when pct >= 0.50, do: :scholar
  defp tier_for(pct, _sage?) when pct >= 0.25, do: :student
  defp tier_for(_pct, _sage?), do: nil

  defp label_for(nil, _name), do: nil
  defp label_for(_tier, nil), do: nil
  defp label_for(tier, name), do: "#{name} #{@tier_names[tier]}"

  defp next_tier(:sage), do: nil
  defp next_tier(nil), do: :student
  defp next_tier(tier) do
    idx = Enum.find_index(@tier_order, &(&1 == tier))
    Enum.at(@tier_order, idx + 1)
  end

  # Raw-% thresholds for the lower tiers; Sage is set-based so no page target.
  @tier_threshold %{student: 0.25, scholar: 0.50, expert: 0.75}

  defp pages_to_next(:sage, _personal), do: nil
  defp pages_to_next(_tier, %{pct: nil}), do: nil
  defp pages_to_next(_tier, %{total: 0}), do: nil
  defp pages_to_next(tier, %{covered: covered, total: total}) do
    case next_tier(tier) do
      :sage -> nil
      nil -> nil
      nt -> max(0, ceil(@tier_threshold[nt] * total) - covered)
    end
  end
```

(Verify `Games.get_game/1` returns a struct with `.name` — confirmed in the coverage engine work at `games.ex:459`.)

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task4.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): title_for tiers + sage"
```

---

### Task 5: `gaps_enriched/1`

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Consumes: existing `gaps/1`; `RuleMaven.Games.Chunk` (`document_id`, `page_number`, `chunk_index`, `content`, `section_label`).
- Produces: `gaps_enriched(game_id) :: [%{document_id, page, label, snippet}]` — uncovered pages across the game's published docs, each with a `snippet` (first line of the lowest-`chunk_index` chunk on that `page_number`) and `label` (that chunk's `section_label` if present, else nil). Ordered by document then page.

- [ ] **Step 1: Write failing test**

```elixir
describe "gaps_enriched/1" do
  test "returns uncovered pages with a snippet from chunk text" do
    game = game_fixture()
    doc = published_doc(game, %{page_count: 3})
    # page 2 covered (community), pages 1 and 3 are gaps
    Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 2})

    Repo.insert!(%RuleMaven.Games.Chunk{
      document_id: doc.id, page_number: 1, chunk_index: 0,
      content: "Setup\nPlace the board in the center.", section_label: "Setup"
    })
    Repo.insert!(%RuleMaven.Games.Chunk{
      document_id: doc.id, page_number: 3, chunk_index: 0,
      content: "Winning the game\nFirst to 10 points wins.", section_label: nil
    })

    gaps = Coverage.gaps_enriched(game.id)
    assert [%{page: 1, label: "Setup", snippet: "Setup"}, %{page: 3, snippet: "Winning the game"}] =
             Enum.map(gaps, &Map.take(&1, [:page, :label, :snippet]))
  end
end
```

(Confirm `RuleMaven.Games.Chunk` field names — `page_number`, `chunk_index`, `content`, `section_label` were verified present. Confirm `Chunk` can be inserted directly or via a changeset in tests.)

- [ ] **Step 2: Run, verify fails.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task5.log`
  Expected: FAIL — undefined.

- [ ] **Step 3: Implement** (append to `coverage.ex`)

```elixir
  alias RuleMaven.Games.Chunk

  @doc "Uncovered pages across the game's published docs, enriched with a text snippet."
  def gaps_enriched(game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    Enum.flat_map(docs, fn doc_id ->
      snippets = page_snippets(doc_id)

      doc_id
      |> gaps()
      |> Enum.map(fn page ->
        {label, snippet} = Map.get(snippets, page, {nil, nil})
        %{document_id: doc_id, page: page, label: label, snippet: snippet}
      end)
    end)
  end

  # For each page_number in a document: {section_label, first_line_of_content}
  # taken from the lowest chunk_index chunk on that page.
  defp page_snippets(doc_id) do
    Repo.all(
      from c in Chunk,
        where: c.document_id == ^doc_id and not is_nil(c.page_number),
        order_by: [asc: c.page_number, asc: c.chunk_index],
        select: {c.page_number, c.section_label, c.content}
    )
    |> Enum.reduce(%{}, fn {page, label, content}, acc ->
      Map.put_new(acc, page, {label, first_line(content)})
    end)
  end

  defp first_line(nil), do: nil
  defp first_line(content) do
    content |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end
```

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task5.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): gaps_enriched with chunk snippets"
```

---

### Task 6: `contribution_credit/2`

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_personal_test.exs`

**Interfaces:**
- Produces: `contribution_credit(user_id, game_id) :: non_neg_integer` — count of `document_page_coverages` rows across the game's published docs where `first_covered_by_user_id == user_id`.

- [ ] **Step 1: Write failing test**

```elixir
describe "contribution_credit/2" do
  test "counts only this user's first-covered pages in the game" do
    game = game_fixture()
    doc = published_doc(game)
    u1 = RuleMaven.AccountsFixtures.user_fixture()
    u2 = RuleMaven.AccountsFixtures.user_fixture()

    Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 1, first_covered_by_user_id: u1.id})
    Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 2, first_covered_by_user_id: u1.id})
    Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 3, first_covered_by_user_id: u2.id})

    assert Coverage.contribution_credit(u1.id, game.id) == 2
    assert Coverage.contribution_credit(u2.id, game.id) == 1
  end
end
```

- [ ] **Step 2: Run, verify fails.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task6.log`
  Expected: FAIL — undefined.

- [ ] **Step 3: Implement** (append to `coverage.ex`)

```elixir
  @doc "How many pages this user was first to ground, across the game's published docs."
  def contribution_credit(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    doc_ids =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    Repo.aggregate(
      from(p in PageCoverage,
        where: p.document_id in ^doc_ids and p.first_covered_by_user_id == ^user_id
      ),
      :count
    )
  end
```

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven/coverage_personal_test.exs 2>&1 | tee ./tmp/incentives_task6.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_personal_test.exs
git commit -m "feat(incentives): contribution_credit count"
```

---

### Task 7: Personal-coverage instrumentation in `show.ex`

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex`
- Test: `test/rule_maven_web/live/game_live/coverage_incentives_test.exs`

**Interfaces:**
- Consumes: `Coverage.record_personal/2`; `socket.assigns.current_user`, `socket.assigns.conversation` (assistant messages carry `:citations`, each citation map now carrying `"document_id"` after the Phase-A hardening).
- Produces: private `record_personal_coverage(socket)` — best-effort; extracts citations from grounded assistant messages in `@conversation` and calls `Coverage.record_personal/2` for the logged-in user. Returns the socket unchanged.

- [ ] **Step 1: Read the two call sites.** In `show.ex`, locate:
  - the conversation-load/open path that ends with `assign(:conversation, conversation)` (around line 3111);
  - the fresh-answer-arrival handler where a streamed assistant message gets its final `citations` (search `%{id: ^question_log_id, role: :assistant}` around lines 2812 / 3269).
  Confirm assistant messages expose `:citations` and `current_user` is a struct with `.id` (anonymous users may have a sentinel — check how `current_user_id`/`uid` is derived at line 303).

- [ ] **Step 2: Write failing test** (`coverage_incentives_test.exs`) — test the helper's contract directly (driving the full LiveView answer stream is impractical; assert the observable behavior the helper guarantees):

```elixir
defmodule RuleMavenWeb.GameLive.CoverageIncentivesTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures
  import Ecto.Query
  alias RuleMaven.Coverage
  alias RuleMaven.Coverage.UserPageCoverage
  alias RuleMaven.Repo

  defp published_doc(game) do
    {:ok, doc} =
      %RuleMaven.Games.Document{game_id: game.id}
      |> RuleMaven.Games.Document.changeset(%{label: "Rulebook", status: "published", page_count: 10})
      |> Repo.insert()
    doc
  end

  test "grounded assistant citations stamp the viewer's personal coverage" do
    game = game_fixture()
    doc = published_doc(game)
    user = RuleMaven.AccountsFixtures.user_fixture()

    # Simulate what the show.ex helper extracts: citations from a grounded assistant msg.
    conversation = [
      %{role: :user, content: "q"},
      %{role: :assistant, citations: [%{"document_id" => doc.id, "page" => 5}]}
    ]

    citations =
      conversation
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.flat_map(&(&1[:citations] || []))

    assert {:ok, 1} = Coverage.record_personal(user.id, citations)
    assert Repo.aggregate(from(u in UserPageCoverage, where: u.user_id == ^user.id), :count) == 1
  end
end
```

  (This locks the extraction contract the helper must implement. The helper itself is thin glue over `record_personal/2`, which is unit-tested in Tasks 2-6.)

- [ ] **Step 3: Run, verify passes** (it exercises `record_personal/2`, already implemented — this test guards the extraction shape the helper uses).
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task7.log`
  Expected: PASS.

- [ ] **Step 4: Implement the helper + wire both call sites** in `show.ex`:

```elixir
  # Best-effort: stamp the current user's personal coverage from grounded
  # assistant answers now visible in the conversation. Never breaks render.
  defp record_personal_coverage(socket) do
    user = socket.assigns[:current_user]

    if user && is_integer(user.id) do
      citations =
        (socket.assigns[:conversation] || [])
        |> Enum.filter(&(Map.get(&1, :role) == :assistant))
        |> Enum.flat_map(&(Map.get(&1, :citations) || []))

      try do
        RuleMaven.Coverage.record_personal(user.id, citations)
      rescue
        e -> require Logger; Logger.warning("record_personal_coverage failed: #{inspect(e)}")
      end
    end

    socket
  end
```

  Call `|> record_personal_coverage()` on the socket right after the conversation is (re)assigned at the load/open path (after `assign(:conversation, conversation)`, ~line 3111) and after the fresh-answer handler updates the conversation with final citations (~2812 / 3269). Anonymous/guest users (non-integer or nil id) are skipped by the guard — verify how guests are represented (line 303's `uid`) and adjust the guard if guests use a non-`nil` sentinel.

- [ ] **Step 5: Run the test file + the existing show/game_live tests touched; keep green.**
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task7.log`
  Expected: PASS; `mix compile --warnings-as-errors` clean.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/coverage_incentives_test.exs
git commit -m "feat(incentives): stamp personal coverage on grounded answer view"
```

---

### Task 8: Community coverage meter + gap panel (sidebar component)

**Files:**
- Create: `lib/rule_maven_web/live/game_live/coverage_panel.ex`
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (assign coverage data on mount/game-load; render the panel in `.question-sidebar`)
- Test: `test/rule_maven_web/live/game_live/coverage_incentives_test.exs` (render assertions)

**Interfaces:**
- Consumes: `Coverage.for_game/1`, `Coverage.gaps_enriched/1`, `Coverage.contribution_credit/2`.
- Produces: `RuleMavenWeb.GameLive.CoveragePanel.coverage_panel/1` function component. Assigns: `%{for_game, gaps, credit}`.

- [ ] **Step 1: Write failing render test** — mount the game LiveView (use the repo's existing LiveView test helper / `live/2`, mirror an existing `game_live` test) for a game with a published doc + one covered page + one gap, and assert the sidebar shows the coverage % and a gap snippet.

```elixir
# In coverage_incentives_test.exs — switch to a ConnCase-based LiveView test module
# if the repo's game_live tests use RuleMaven.ConnCase + Phoenix.LiveViewTest.
test "sidebar renders coverage percent and a gap nudge", %{conn: conn} do
  # ... set up game + published doc(page_count 2) + community coverage on page 1
  # + a chunk on page 2 with content "Trading\n..." ; log in a user ...
  {:ok, _view, html} = live(conn, ~p"/games/#{game_hashid}")
  assert html =~ "Coverage"
  assert html =~ "50%"          # 1 of 2 pages
  assert html =~ "Trading"      # gap snippet for page 2
end
```

  (Find the real route helper + game hashid convention used by existing `game_live` tests — the app uses `RuleMaven.Hashid` in URLs, not raw ids. Copy the login + navigation setup from an existing passing `game_live` feature/LiveView test.)

- [ ] **Step 2: Run, verify fails** (panel not rendered).
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task8.log`
  Expected: FAIL.

- [ ] **Step 3: Write the component** (`coverage_panel.ex`) — mobile-first, follows existing sidebar styling (read `.question-sidebar` markup at `show.ex:3523-3542` and reuse its class conventions):

```elixir
defmodule RuleMavenWeb.GameLive.CoveragePanel do
  use RuleMavenWeb, :html

  attr :for_game, :map, required: true
  attr :gaps, :list, default: []
  attr :credit, :integer, default: 0

  def coverage_panel(assigns) do
    ~H"""
    <div class="coverage-panel">
      <div class="coverage-meter">
        <span class="coverage-label">Rulebook coverage</span>
        <span class="coverage-pct">{pct_text(@for_game.pct)}</span>
        <div class="coverage-bar" role="progressbar">
          <div class="coverage-bar-fill" style={"width:#{bar_width(@for_game.pct)}"}></div>
        </div>
      </div>

      <p :if={@credit > 0} class="coverage-credit">You were first to ground {@credit} pages</p>

      <details :if={@gaps != []} class="coverage-gaps">
        <summary>Help fill the gaps ({length(@gaps)})</summary>
        <ul>
          <li :for={g <- Enum.take(@gaps, 20)}>
            <span class="gap-page">p.{g.page}</span>
            <span class="gap-snippet">{g.label || g.snippet}</span>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp pct_text(nil), do: "—"
  defp pct_text(pct), do: "#{round(pct * 100)}%"
  defp bar_width(nil), do: "0%"
  defp bar_width(pct), do: "#{round(pct * 100)}%"
end
```

  Add minimal CSS for `.coverage-panel`/`.coverage-bar`/etc. in the app's existing stylesheet, honoring the mobile-first + contrast-floor standing rules. In `show.ex`: assign `coverage_for_game`, `coverage_gaps`, `coverage_credit` when the game loads (guard each read so failure hides the panel), and render `<CoveragePanel.coverage_panel .../>` inside `.question-sidebar`.

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task8.log`
  Expected: PASS. Then **browser-verify at 390px** (major UI change per hard rule): panel readable, bar not overflowing, gap list scrolls within the sidebar.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/coverage_panel.ex lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/coverage_incentives_test.exs assets
git commit -m "feat(incentives): sidebar coverage meter + gap panel"
```

---

### Task 9: Personal title beside the mastery HUD

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` (add title to/near `mastery_hud`)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (assign `coverage_title`, pass to SubBar)
- Test: `test/rule_maven_web/live/game_live/coverage_incentives_test.exs`

**Interfaces:**
- Consumes: `Coverage.title_for/2` → `%{tier, label, pct, next_tier, pages_to_next}`.
- Produces: title rendered next to `mastery_hud` (`sub_bar.ex:82/97`). SubBar gains a `coverage_title` assign.

- [ ] **Step 1: Write failing test** — a logged-in user at ≥25% personal coverage sees their title in the sub-bar.

```elixir
test "sub-bar shows the personal title once earned", %{conn: conn} do
  # ... game + published doc(page_count 4) + user with 1 personal page (25%) ...
  {:ok, _view, html} = live(conn, ~p"/games/#{game_hashid}")
  assert html =~ "Student"
end
```

- [ ] **Step 2: Run, verify fails.**
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task9.log`
  Expected: FAIL.

- [ ] **Step 3: Implement.** In `show.ex`, assign `coverage_title = Coverage.title_for(user.id, game.id)` (guarded), pass to SubBar alongside `game_mastery`. In `sub_bar.ex`, near `mastery_hud` (line 82), render:

```elixir
<span :if={@coverage_title && @coverage_title.label} class="coverage-title" title="Rulebook mastery">
  {@coverage_title.label}
  <span :if={@coverage_title.pages_to_next} class="coverage-title-next">
    · {@coverage_title.pages_to_next} to {next_label(@coverage_title.next_tier)}
  </span>
</span>
```

  Add a `next_label/1` helper mapping the tier atom to its display name (reuse the same names as `@tier_names` — `:student → "Student"`, etc.; keep the single source in `Coverage` and expose it, or duplicate the tiny map in the component with a comment pointing at `Coverage`). Default the `coverage_title` assign to `nil` so games without it render unchanged.

- [ ] **Step 4: Run, verify passes.**
  Run: `mix test test/rule_maven_web/live/game_live/coverage_incentives_test.exs 2>&1 | tee ./tmp/incentives_task9.log`
  Expected: PASS. **Browser-verify at 390px** — title fits in the sub-bar without wrapping/clipping (respect the sub-bar nowrap-clip note: the pill must not run off-screen).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/sub_bar.ex lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/coverage_incentives_test.exs
git commit -m "feat(incentives): personal per-game title in sub-bar"
```

---

### Task 10: /help + tours upkeep

**Files:**
- Modify: the `/help` content source + the tours definition (grep for where existing help sections and tour steps live — e.g. a help LiveView/template and a `tours`/`help_tours` module).
- Test: whatever test guards help/tours content (mirror existing).

**Interfaces:** none (content only).

- [ ] **Step 1: Locate help + tours sources.** `rg -n "def tours|help_section|Getting Started|tours_seen" lib/rule_maven_web` and find the `/help` page. Read one existing section/tour step to match structure.

- [ ] **Step 2: Add a short "Rulebook coverage & titles" help section** explaining: the community coverage meter (what it means, gaps to fill), that reading or asking grounds pages, and the per-game titles (Student → Sage). Keep copy tight, match existing voice.

- [ ] **Step 3: Add/extend a tour step** pointing at the sidebar coverage panel (if the tours framework supports anchoring to the panel; otherwise a one-line mention in the existing game tour).

- [ ] **Step 4: Run the help/tours test (if any) + `mix compile --warnings-as-errors`.**
  Run: `mix test <help_or_tours_test_file> 2>&1 | tee ./tmp/incentives_task10.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(incentives): help + tours note for coverage & titles"
```

---

## Final verification

- [ ] Run all touched test files together, tee to `./tmp/incentives_all.log`; zero failures, zero warnings.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] 390px browser check of the sidebar meter/gap panel and the sub-bar title.

## Self-review notes (author)

- Spec coverage: data model (T1), context reads (T2–T6), instrumentation (T7), UI meter+gaps (T8), title (T9), help/tours (T10) — all spec sections mapped.
- Denominator parity enforced in `personal_for_game/2` by reusing `for_game/1`'s game-id set + `summarize`/`pct`.
- DRY: `distinct_covered_pairs/1` shared by community + personal write paths (T2).
- Anti-grind: unique `(user_id, document_id, page)` + `ON CONFLICT DO NOTHING` (T1/T2).

## Deploy notes

- 1 migration (`user_page_coverages`). No backfill.
- User-facing: help + tours updated (T10).
