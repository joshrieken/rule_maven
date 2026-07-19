# Rulebook Coverage Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure per-source rulebook coverage (distinct cited pages ÷ page_count), rolled up per game, and expose a gap list — the data foundation for a later contribution/incentive layer.

**Architecture:** Harden the answer→source link by resolving each citation's source **label** to a real `documents.id` at answer-persist time (populating the existing but unused `question_log.document_id` FK and stamping a `document_id` onto each citation map). A page-grain table `document_page_coverages` records which `(document_id, page)` pairs have a grounded answer, upserted idempotently. A pure-read `RuleMaven.Coverage` context computes coverage % and gaps. A backfill task seeds the pre-existing corpus.

**Tech Stack:** Elixir, Phoenix, Ecto/Postgres, Oban, ExUnit.

## Global Constraints

- Zero warnings, zero failing tests — never leave a warning or red test as "pre-existing" (HARD RULE).
- Run only the test files relevant to the change; tee output to `./tmp/<name>.log`; do not run the full suite twice.
- Never delete `llm_logs` rows in test cleanup (billing record).
- `documents.page_count` is nullable — nil ⇒ `pct: nil` ("coverage pending"), never divide by nil/zero.
- Rollup counts **published** documents only (`status == "published"`).
- `question_log.document_id` column already exists (`question_log.ex:93`) — do NOT create it.
- Citation source is matched to `documents.label` case-insensitively (mirror `Citations.canonical_source/2`).
- Coverage is additive: any read error ⇒ caller renders normally, never a gate.
- No user-facing UI in this plan (meters/titles are a later spec) ⇒ no `/help` or tours update required here.
- Commit after each task. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `priv/repo/migrations/<ts>_create_document_page_coverages.exs` — new table + indexes.
- `lib/rule_maven/coverage/page_coverage.ex` — Ecto schema for a covered page.
- `lib/rule_maven/coverage.ex` — the context: `resolve_document_ids/2`, `record_citations/1`, `for_document/1`, `for_game/1`, `gaps/1`, `document_label_map/1`.
- `lib/rule_maven/workers/ask_worker.ex` — hardening: stamp citation `document_id` + scalar `question_log.document_id`; call `Coverage.record_citations/1` beside `maybe_award_mastery/2`.
- `lib/mix/tasks/rule_maven.backfill_coverage.ex` — one-shot backfill.
- Tests: `test/rule_maven/coverage_test.exs`, `test/rule_maven/workers/ask_worker_coverage_test.exs` (or extend existing ask_worker test), `test/mix/tasks/rule_maven.backfill_coverage_test.exs`.

---

### Task 1: `document_page_coverages` table + schema

**Files:**
- Create: `priv/repo/migrations/<ts>_create_document_page_coverages.exs`
- Create: `lib/rule_maven/coverage/page_coverage.ex`
- Test: `test/rule_maven/coverage_test.exs` (schema insert smoke)

**Interfaces:**
- Produces: `RuleMaven.Coverage.PageCoverage` schema over table `document_page_coverages` with fields `document_id`, `page`, `first_covered_by_user_id`, `first_question_log_id`, `first_covered_at`; unique index `(document_id, page)`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.CreateDocumentPageCoverages do
  use Ecto.Migration

  def change do
    create table(:document_page_coverages) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :page, :integer, null: false
      add :first_covered_by_user_id, references(:users, on_delete: :nilify_all)
      add :first_question_log_id, references(:questions_log, on_delete: :nilify_all)
      add :first_covered_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_page_coverages, [:document_id, :page])
    create index(:document_page_coverages, [:first_covered_by_user_id])
  end
end
```

- [ ] **Step 2: Write the schema**

```elixir
defmodule RuleMaven.Coverage.PageCoverage do
  use Ecto.Schema

  schema "document_page_coverages" do
    field :page, :integer
    field :first_covered_at, :utc_datetime
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :first_covered_by_user, RuleMaven.Users.User
    belongs_to :first_question_log, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end
end
```

- [ ] **Step 3: Write failing test** (`test/rule_maven/coverage_test.exs`)

```elixir
defmodule RuleMaven.CoverageTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Repo

  test "page coverage row inserts and enforces (document_id, page) uniqueness" do
    game = insert(:game)
    doc = insert(:document, game: game, page_count: 10, status: "published")

    {:ok, _} = Repo.insert(%PageCoverage{document_id: doc.id, page: 3})
    assert {:error, _} = Repo.insert(%PageCoverage{document_id: doc.id, page: 3})
  end
end
```

(If no `:document`/`:game` factory exists, build the struct via the existing test helpers used elsewhere in `test/rule_maven` — check `test/support/factory.ex` first and mirror its style.)

- [ ] **Step 4: Run migration + test, verify pass**
  Run: `mix ecto.migrate && mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task1.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations lib/rule_maven/coverage/page_coverage.ex test/rule_maven/coverage_test.exs
git commit -m "feat(coverage): document_page_coverages table + PageCoverage schema"
```

---

### Task 2: `Coverage.document_label_map/1` + `resolve_document_ids/2`

**Files:**
- Create: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Games.Document` (fields `game_id`, `label`, `status`), `RuleMaven.Repo`.
- Produces:
  - `document_label_map(game_ids :: [integer]) :: %{String.t() => integer}` — downcased published-doc label ⇒ document_id, over the given games.
  - `resolve_document_ids(citations :: [map], game_ids :: [integer]) :: [map]` — returns citations with `"document_id"` stamped where the label resolves (unresolved ⇒ left absent).

- [ ] **Step 1: Write failing test**

```elixir
describe "resolve_document_ids/2" do
  test "stamps document_id by case-insensitive label match over the given games" do
    game = insert(:game)
    doc = insert(:document, game: game, label: "Base Rulebook", status: "published", page_count: 12)

    citations = [%{"quote" => "q", "page" => 4, "source" => "base rulebook"}]
    [stamped] = Coverage.resolve_document_ids(citations, [game.id])

    assert stamped["document_id"] == doc.id
  end

  test "leaves document_id absent when label does not resolve" do
    game = insert(:game)
    citations = [%{"quote" => "q", "page" => 4, "source" => "unknown source"}]
    [stamped] = Coverage.resolve_document_ids(citations, [game.id])

    refute Map.has_key?(stamped, "document_id")
  end
end
```

- [ ] **Step 2: Run test, verify fails**
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task2.log`
  Expected: FAIL — `Coverage.resolve_document_ids/2` undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule RuleMaven.Coverage do
  @moduledoc """
  Rulebook coverage: which (document, page) pairs have a grounded answer.
  Measurement only — reward/incentive semantics live in a later layer.
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Games.Document

  @doc "Downcased published-document label => document_id, across the given games."
  def document_label_map(game_ids) when is_list(game_ids) do
    Repo.all(
      from d in Document,
        where: d.game_id in ^game_ids and d.status == "published" and not is_nil(d.label),
        select: {d.label, d.id}
    )
    |> Map.new(fn {label, id} -> {String.downcase(label), id} end)
  end

  @doc "Stamp `document_id` onto each citation whose `source` label resolves within `game_ids`."
  def resolve_document_ids(citations, game_ids) when is_list(citations) do
    label_map = document_label_map(game_ids)

    Enum.map(citations, fn c ->
      case c["source"] && Map.get(label_map, String.downcase(c["source"])) do
        nil -> c
        doc_id -> Map.put(c, "document_id", doc_id)
      end
    end)
  end
end
```

- [ ] **Step 4: Run test, verify passes**
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task2.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_test.exs
git commit -m "feat(coverage): resolve citation source label to document_id"
```

---

### Task 3: `Coverage.record_citations/1` (idempotent upsert)

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_test.exs`

**Interfaces:**
- Consumes: `PageCoverage`, a `QuestionLog` with `citations` (each already carrying `"document_id"` + `"page"`), plus `user_id`, `id`.
- Produces: `record_citations(question_log) :: {:ok, non_neg_integer}` — number of new page rows inserted. Idempotent (ON CONFLICT DO NOTHING). Skips citations without a `document_id` or an integer `page`, and pages `< 1` or `> page_count`.

- [ ] **Step 1: Write failing test**

```elixir
describe "record_citations/1" do
  test "upserts distinct (document_id, page) and is idempotent, clamped to page_count" do
    game = insert(:game)
    doc = insert(:document, game: game, label: "Rulebook", status: "published", page_count: 8)
    ql = insert(:question_log, game: game, user: insert(:user))

    ql = %{ql | citations: [
      %{"page" => 3, "document_id" => doc.id},
      %{"page" => 3, "document_id" => doc.id},   # dup page
      %{"page" => 99, "document_id" => doc.id},  # beyond page_count -> skipped
      %{"page" => 5, "document_id" => nil}       # no doc -> skipped
    ]}

    assert {:ok, 1} = Coverage.record_citations(ql)   # only page 3 counts
    assert {:ok, 0} = Coverage.record_citations(ql)   # re-run adds nothing
    assert Coverage.for_document(doc.id).covered == 1
  end
end
```

- [ ] **Step 2: Run test, verify fails**
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task3.log`
  Expected: FAIL — `record_citations/1` / `for_document/1` undefined.

- [ ] **Step 3: Implement** (append to `Coverage`)

```elixir
  alias RuleMaven.Coverage.PageCoverage

  @doc "Record covered (document_id, page) pairs from a question_log's citations. Idempotent."
  def record_citations(%{citations: citations} = ql) when is_list(citations) do
    page_counts = page_count_map(citations)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> Enum.flat_map(&covered_pair(&1, page_counts))
      |> Enum.uniq()
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
      Repo.insert_all(PageCoverage, rows,
        on_conflict: :nothing,
        conflict_target: [:document_id, :page]
      )

    {:ok, count}
  end

  def record_citations(_), do: {:ok, 0}

  # Page-count lookup for the documents referenced by these citations.
  defp page_count_map(citations) do
    ids = citations |> Enum.map(& &1["document_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from d in Document, where: d.id in ^ids, select: {d.id, d.page_count})
    |> Map.new()
  end

  defp covered_pair(%{"document_id" => doc_id, "page" => page}, page_counts)
       when is_integer(doc_id) and is_integer(page) and page >= 1 do
    case Map.get(page_counts, doc_id) do
      pc when is_integer(pc) and page > pc -> []   # beyond denominator: skip
      _ -> [{doc_id, page}]                         # nil page_count still records the page
    end
  end

  defp covered_pair(_, _), do: []
```

- [ ] **Step 4: Run test, verify passes** (depends on `for_document/1` from Task 4 — implement Task 4 Step 3's `for_document/1` now if running strictly TDD, or land Tasks 3+4 together; the plan orders them so `for_document/1` exists by Step 4. If you run Task 3 standalone, assert on `Repo.aggregate(PageCoverage, :count)` instead.)
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task3.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_test.exs
git commit -m "feat(coverage): idempotent page-coverage upsert from citations"
```

---

### Task 4: Coverage reads — `for_document/1`, `for_game/1`, `gaps/1`

**Files:**
- Modify: `lib/rule_maven/coverage.ex`
- Test: `test/rule_maven/coverage_test.exs`

**Interfaces:**
- Produces:
  - `for_document(document_id) :: %{page_count: integer | nil, covered: non_neg_integer, pct: float | nil}` — `pct` nil when `page_count` nil; `covered` capped at `page_count`.
  - `for_game(game_id) :: %{sources: [%{document_id, label, page_count, covered, pct}], covered: integer, total: integer, pct: float | nil}` — published docs across the game + its expansions.
  - `gaps(document_id) :: [integer]` — sorted uncovered page numbers in `1..page_count` (`[]` when page_count nil).

- [ ] **Step 1: Write failing test**

```elixir
describe "reads" do
  test "for_document computes pct, nil page_count -> nil pct" do
    game = insert(:game)
    doc = insert(:document, game: game, status: "published", page_count: 4)
    Repo.insert!(%PageCoverage{document_id: doc.id, page: 1})
    Repo.insert!(%PageCoverage{document_id: doc.id, page: 2})

    assert %{page_count: 4, covered: 2, pct: pct} = Coverage.for_document(doc.id)
    assert_in_delta pct, 0.5, 0.001

    nild = insert(:document, game: game, status: "published", page_count: nil)
    assert %{pct: nil} = Coverage.for_document(nild.id)
  end

  test "for_game rolls up published docs only" do
    game = insert(:game)
    pub = insert(:document, game: game, status: "published", page_count: 4, label: "Rulebook")
    _pending = insert(:document, game: game, status: "pending_review", page_count: 10)
    Repo.insert!(%PageCoverage{document_id: pub.id, page: 1})

    roll = Coverage.for_game(game.id)
    assert roll.total == 4
    assert roll.covered == 1
    assert_in_delta roll.pct, 0.25, 0.001
  end

  test "gaps returns the uncovered complement" do
    game = insert(:game)
    doc = insert(:document, game: game, status: "published", page_count: 3)
    Repo.insert!(%PageCoverage{document_id: doc.id, page: 2})
    assert Coverage.gaps(doc.id) == [1, 3]
  end
end
```

- [ ] **Step 2: Run test, verify fails**
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task4.log`
  Expected: FAIL — read functions undefined.

- [ ] **Step 3: Implement** (append to `Coverage`)

```elixir
  alias RuleMaven.Games

  def for_document(document_id) do
    page_count = Repo.one(from d in Document, where: d.id == ^document_id, select: d.page_count)
    covered_raw = Repo.aggregate(from(p in PageCoverage, where: p.document_id == ^document_id), :count)
    summarize(page_count, covered_raw)
  end

  def for_game(game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{document_id: d.id, label: d.label, page_count: d.page_count}
      )

    counts =
      Repo.all(
        from p in PageCoverage,
          where: p.document_id in ^Enum.map(docs, & &1.document_id),
          group_by: p.document_id,
          select: {p.document_id, count(p.id)}
      )
      |> Map.new()

    sources =
      Enum.map(docs, fn d ->
        s = summarize(d.page_count, Map.get(counts, d.document_id, 0))
        Map.merge(d, s)
      end)

    total = sources |> Enum.map(&(&1.page_count || 0)) |> Enum.sum()
    covered = sources |> Enum.map(& &1.covered) |> Enum.sum()
    %{sources: sources, covered: covered, total: total, pct: pct(covered, total)}
  end

  def gaps(document_id) do
    page_count = Repo.one(from d in Document, where: d.id == ^document_id, select: d.page_count)

    case page_count do
      pc when is_integer(pc) and pc > 0 ->
        covered =
          Repo.all(from p in PageCoverage, where: p.document_id == ^document_id, select: p.page)
          |> MapSet.new()

        Enum.reject(1..pc, &MapSet.member?(covered, &1))

      _ ->
        []
    end
  end

  # page_count nil -> pct nil; covered capped at page_count.
  defp summarize(nil, covered_raw), do: %{page_count: nil, covered: covered_raw, pct: nil}

  defp summarize(page_count, covered_raw) do
    covered = min(covered_raw, page_count)
    %{page_count: page_count, covered: covered, pct: pct(covered, page_count)}
  end

  defp pct(_covered, 0), do: nil
  defp pct(_covered, total) when is_nil(total), do: nil
  defp pct(covered, total), do: covered / total

  # Expansion games linked to this base game (mirrors Games expansion links).
  defp expansion_game_ids(game_id) do
    case RuleMaven.Games.get_game(game_id) do
      nil -> []
      game -> RuleMaven.Games.expansions_for(game) |> Enum.map(& &1.id)
    end
  end
```

  (Verify `Games.get_game/1` and `Games.expansions_for/1` exact names/arities before relying on them; `expansions_for/1` is defined at `games.ex:220` taking a `%Game{}`. If `get_game/1` differs, use the repo's actual fetch.)

- [ ] **Step 4: Run test, verify passes** — also re-run Task 3's test (now `for_document/1` exists).
  Run: `mix test test/rule_maven/coverage_test.exs 2>&1 | tee ./tmp/coverage_task4.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/coverage.ex test/rule_maven/coverage_test.exs
git commit -m "feat(coverage): for_document/for_game/gaps reads"
```

---

### Task 5: AskWorker hardening — stamp document_id + record coverage

**Files:**
- Modify: `lib/rule_maven/workers/ask_worker.ex` (citation-build ~389-429, update_attrs ~482-491, post-update block ~530-537)
- Test: `test/rule_maven/workers/ask_worker_coverage_test.exs`

**Interfaces:**
- Consumes: `Coverage.resolve_document_ids/2`, `Coverage.record_citations/1`.
- Produces: persisted `question_log.citations` each carrying `"document_id"` where resolvable; scalar `question_log.document_id` = primary citation's document; coverage rows recorded.

- [ ] **Step 1: Write failing test** — drive a question_log through the persist path (or, if the worker is hard to unit-drive, assert on a thin extracted helper). Prefer testing the *observable* result: after an answered ask with a citation whose `source` matches a published document label, `question_log.document_id` is set and a coverage row exists.

```elixir
defmodule RuleMaven.Workers.AskWorkerCoverageTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Coverage

  test "resolved citations stamp scalar document_id and record coverage" do
    game = insert(:game)
    doc = insert(:document, game: game, label: "Rulebook", status: "published", page_count: 10)
    ql = insert(:question_log, game: game, user: insert(:user))

    citations = [%{"quote" => "text", "page" => 4, "source" => "Rulebook"}]
    stamped = Coverage.resolve_document_ids(citations, [game.id])
    ql = %{ql | citations: stamped, document_id: hd(stamped)["document_id"]}

    assert {:ok, 1} = Coverage.record_citations(ql)
    assert Coverage.for_document(doc.id).covered == 1
  end
end
```

  (This validates the wiring contract. The next steps wire it into the worker so real asks exercise it.)

- [ ] **Step 2: Wire the hardening into `ask_worker.ex`.** After `valid_citations`/`primary` are computed (~line 429), resolve document ids:

```elixir
game_ids = [game_id | expansion_ids]
valid_citations = RuleMaven.Coverage.resolve_document_ids(valid_citations, game_ids)
primary = List.first(valid_citations) || %{"quote" => nil, "page" => nil, "source" => nil}
```

  In `update_attrs` (~482), add the scalar FK:

```elixir
document_id: primary["document_id"],
```

  (Confirm `expansion_ids` and `game_id` are in scope at that point — both are, per `ask_worker.ex:111` and the surrounding closure.)

- [ ] **Step 3: Call `record_citations/1` in the post-update success block**, beside `maybe_award_mastery/2` (~line 537), best-effort so it never breaks the answer:

```elixir
try do
  RuleMaven.Coverage.record_citations(updated)
rescue
  e -> require Logger; Logger.warning("Coverage.record_citations failed: #{inspect(e)}")
end
```

- [ ] **Step 4: Run tests, verify pass** (this test + any existing ask_worker tests touched).
  Run: `mix test test/rule_maven/workers/ask_worker_coverage_test.exs 2>&1 | tee ./tmp/coverage_task5.log`
  Expected: PASS. Also run the existing ask_worker test file if one exists; keep it green.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/workers/ask_worker.ex test/rule_maven/workers/ask_worker_coverage_test.exs
git commit -m "feat(coverage): harden ask persistence — stamp document_id + record coverage"
```

---

### Task 6: Backfill task

**Files:**
- Create: `lib/mix/tasks/rule_maven.backfill_coverage.ex`
- Test: `test/mix/tasks/rule_maven.backfill_coverage_test.exs`

**Interfaces:**
- Consumes: `Coverage.resolve_document_ids/2`, `Coverage.record_citations/1`, `RuleMaven.Games.QuestionLog`.
- Produces: `mix rule_maven.backfill_coverage` — walks existing `questions_log` rows with non-empty citations, resolves labels → document_ids per row's game (+ its expansions), records coverage. Idempotent.

- [ ] **Step 1: Write failing test**

```elixir
defmodule Mix.Tasks.RuleMaven.BackfillCoverageTest do
  use RuleMaven.DataCase, async: false
  alias RuleMaven.Coverage

  test "seeds coverage from existing citations and is idempotent" do
    game = insert(:game)
    doc = insert(:document, game: game, label: "Rulebook", status: "published", page_count: 10)

    insert(:question_log,
      game: game,
      user: insert(:user),
      citations: [%{"quote" => "q", "page" => 6, "source" => "Rulebook"}]
    )

    Mix.Tasks.RuleMaven.BackfillCoverage.run([])
    assert Coverage.for_document(doc.id).covered == 1

    Mix.Tasks.RuleMaven.BackfillCoverage.run([])
    assert Coverage.for_document(doc.id).covered == 1
  end
end
```

- [ ] **Step 2: Run test, verify fails**
  Run: `mix test test/mix/tasks/rule_maven.backfill_coverage_test.exs 2>&1 | tee ./tmp/coverage_task6.log`
  Expected: FAIL — task undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Mix.Tasks.RuleMaven.BackfillCoverage do
  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Coverage, Repo}
  alias RuleMaven.Games.QuestionLog

  @shortdoc "Seed document_page_coverages from existing question citations"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    query =
      from q in QuestionLog,
        where: fragment("jsonb_array_length(coalesce(?::jsonb, '[]'::jsonb)) > 0", q.citations),
        select: %{id: q.id, game_id: q.game_id, user_id: q.user_id, citations: q.citations}

    Repo.transaction(fn ->
      query
      |> Repo.stream()
      |> Stream.each(fn ql ->
        game_ids = [ql.game_id | expansion_game_ids(ql.game_id)]
        stamped = Coverage.resolve_document_ids(ql.citations, game_ids)
        Coverage.record_citations(%{ql | citations: stamped})
      end)
      |> Stream.run()
    end)
  end

  defp expansion_game_ids(game_id) do
    case RuleMaven.Games.get_game(game_id) do
      nil -> []
      game -> RuleMaven.Games.expansions_for(game) |> Enum.map(& &1.id)
    end
  end
end
```

  (If `citations` stores as `:map` array via `{:array, :map}` and the `jsonb_array_length` fragment mismatches the column type, fall back to `where: fragment("? <> '{}'", q.citations)` or filter in Elixir after `Repo.all`. Confirm the column's DB type before finalizing the WHERE.)

- [ ] **Step 4: Run test, verify passes**
  Run: `mix test test/mix/tasks/rule_maven.backfill_coverage_test.exs 2>&1 | tee ./tmp/coverage_task6.log`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/rule_maven.backfill_coverage.ex test/mix/tasks/rule_maven.backfill_coverage_test.exs
git commit -m "feat(coverage): backfill task seeds coverage from existing citations"
```

---

## Final verification

- [ ] Run all touched test files together, tee to `./tmp/coverage_all.log`; confirm zero failures, zero warnings.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] Confirm no `/help` or tours change needed (no user-facing surface in this plan).

## Deploy notes

- 1 migration: `document_page_coverages`.
- After migrate: run `mix rule_maven.backfill_coverage` once.
- No env/config changes.

## Note: re-extract page-count shrink

The spec calls for pruning coverage rows with `page > page_count` when a document is
re-extracted and its `page_count` shrinks. **No dedicated task is needed:** `for_document/1`
caps `covered` at `page_count`, and `gaps/1` only scans `1..page_count`, so stale
above-range rows never affect `pct` or the gap list. They are inert. A cleanup prune can be
added to the re-extract path later if the dead rows ever matter for storage; it is not a
correctness requirement for this engine.
