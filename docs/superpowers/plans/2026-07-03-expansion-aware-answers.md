# Expansion-Aware Answers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cached answers, setup checklists, and cheat sheets correct for whichever expansion set a user is playing with, and remember that set per user.

**Architecture:** Three independent features, in dependency order. (A) The answer pool + same-user cache tiers get keyed by the exact (sorted) expansion-id set stored on each `questions_log` row, so a base-only answer never serves an expansion ask and vice versa; expansion rulebook changes invalidate base-game answers that used them. (B) A `user_expansion_selections` table persists each user's per-base-game expansion choice, defaulting from their collection. (C) A per-expansion "delta" (components / setup changes / rule changes) is generated once during the expansion's prepare pipeline and composed at display time into the base game's setup checklist card and cheat sheet page — linear cost, no per-combo generation.

**Tech Stack:** Phoenix LiveView, Ecto/Postgres (pgvector), Oban, Settings-based state machines, Prompts registry.

## Global Constraints

- LLM prompts (system + user) go in the editable `RuleMaven.Prompts` registry — never hardcoded (standing rule).
- Background/slow work must be durable Oban jobs reporting to the unified Jobs log (`Jobs.start_run/event/finish_run`).
- Never expose raw ids in URLs; `phx-value` ids stay raw (standing rule) — expansion toggle already uses raw ids in phx-value, keep that.
- Expansion-id sets are ALWAYS stored and compared sorted ascending (`Enum.sort/1`). Sort at every boundary that persists or queries.
- Test output: `mix test <file> 2>&1 | tee tmp/<name>.log` — don't run the full suite twice; delete the log when done.
- Commit each completed task (auto-commit rule). Don't push.
- Embeddings are 768-dim (`List.duplicate(0.0, 768)` fixtures, `Pgvector.new/1`).

## File Structure

- `priv/repo/migrations/<ts>_add_expansion_ids_to_questions_log.exs` — new (Task 1)
- `priv/repo/migrations/<ts>_create_expansion_selections.exs` — new (Task 5)
- `lib/rule_maven/games/question_log.ex` — add `expansion_ids` field (Task 1)
- `lib/rule_maven/games.ex` — scope 4 cache lookups (Task 2), extend `invalidate_pool/1` (Task 4), selection API (Task 5)
- `lib/rule_maven/llm.ex` — thread sorted expansion set into lookups (Task 3)
- `lib/rule_maven/workers/ask_worker.ex` — pass set to answer-dup lookup (Task 3)
- `lib/rule_maven_web/live/game_live/show.ex` — store set on logged questions (Task 3), seed/persist selection (Task 6), delta sections in setup card (Task 10)
- `lib/rule_maven/games/expansion_selection.ex` — new schema (Task 5)
- `lib/rule_maven/prompts.ex` — two new registry entries (Task 7)
- `lib/rule_maven/expansion_delta.ex` — new module (Task 8)
- `lib/rule_maven/workers/expansion_delta_worker.ex` — new worker (Task 9)
- `lib/rule_maven/readiness.ex` — enqueue delta in `ensure_enrichments` (Task 9)
- `lib/rule_maven_web/controllers/cheat_sheet_controller.ex` — append delta rules (Task 11)

---

## Feature A — Answer cache keyed by expansion set

### Task 1: `expansion_ids` column on questions_log

**Files:**
- Create: `priv/repo/migrations/20260703170000_add_expansion_ids_to_questions_log.exs`
- Modify: `lib/rule_maven/games/question_log.ex`
- Test: `test/rule_maven/games_expansion_cache_test.exs` (new file)

**Interfaces:**
- Produces: `QuestionLog.expansion_ids :: [integer]`, default `[]`, castable via `Games.log_question/1` attrs.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule RuleMaven.GamesExpansionCacheTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  defp game(name \\ "ExpCache") do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  describe "expansion_ids on questions_log" do
    test "defaults to [] and persists a cast list" do
      g = game()

      {:ok, plain} = Games.log_question(%{game_id: g.id, question: "q", answer: "a"})
      assert Repo.get!(QuestionLog, plain.id).expansion_ids == []

      {:ok, tagged} =
        Games.log_question(%{game_id: g.id, question: "q2", answer: "a2", expansion_ids: [7, 3]})

      assert Repo.get!(QuestionLog, tagged.id).expansion_ids == [7, 3]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: FAIL — `expansion_ids` not a field / column does not exist.

- [ ] **Step 3: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddExpansionIdsToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # The exact (sorted ascending) expansion-id set the answer was computed
      # against. [] = base game only. Cache lookups match on set equality;
      # invalidation matches membership (GIN index below).
      add :expansion_ids, {:array, :integer}, null: false, default: []
    end

    create index(:questions_log, [:expansion_ids], using: "GIN")
  end
end
```

Run: `mix ecto.migrate`

- [ ] **Step 4: Add the schema field + cast**

In `lib/rule_maven/games/question_log.ex`, after the `stale` field (line ~40):

```elixir
    # The exact (sorted) expansion-id set the answer was computed against.
    # [] = base game only. All cache tiers match on set equality so an answer
    # never crosses expansion configurations.
    field :expansion_ids, {:array, :integer}, default: []
```

Add `:expansion_ids` to the `cast` list in `changeset/2` (after `:favorited`).

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260703170000_add_expansion_ids_to_questions_log.exs lib/rule_maven/games/question_log.ex test/rule_maven/games_expansion_cache_test.exs
git commit -m "feat: expansion_ids set on questions_log rows"
```

### Task 2: Scope all four cache lookups by expansion set

**Files:**
- Modify: `lib/rule_maven/games.ex` — `find_similar_question_in_pool/3` (line ~1966), `find_user_duplicate/4` (~2026), `find_user_similar/4` (~2060), `find_user_answer_duplicate/4` (~2097)
- Test: `test/rule_maven/games_expansion_cache_test.exs`

**Interfaces:**
- Consumes: `QuestionLog.expansion_ids` from Task 1.
- Produces (Task 3 calls these):
  - `find_similar_question_in_pool(game_id, embedding, opts)` — new opt `expansion_ids: [integer]` (default `[]`)
  - `find_user_duplicate(game_id, user_id, cleaned, raw, expansion_ids \\ [])`
  - `find_user_similar(game_id, user_id, embedding, opts)` — new opt `expansion_ids` (default `[]`)
  - `find_user_answer_duplicate(game_id, user_id, answer, exclude_id, expansion_ids \\ [])`
  - All compare `q.expansion_ids == ^Enum.sort(expansion_ids)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven/games_expansion_cache_test.exs`:

```elixir
  import Ecto.Query

  defp user do
    Repo.insert!(%RuleMaven.Users.User{
      username: "exp_user_#{System.unique_integer([:positive])}",
      email: "exp#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  # Pooled community row with a unit-axis embedding and the given expansion set.
  defp pooled_q(game, expansion_ids, extra \\ %{}) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "how many cards do I draw?",
            answer: "Draw two cards.",
            visibility: "community",
            expansion_ids: expansion_ids
          },
          extra
        )
      )

    e0 = [1.0 | List.duplicate(0.0, 767)]

    Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
      set: [question_embedding: Pgvector.new(e0), pooled: true]
    )

    Repo.get!(QuestionLog, q.id)
  end

  describe "cache lookups scope by expansion set" do
    setup do
      %{g: game(), e0: [1.0 | List.duplicate(0.0, 767)]}
    end

    test "pool: base answer doesn't serve an expansion ask (and vice versa)", %{g: g, e0: e0} do
      base_row = pooled_q(g, [])

      assert {%{id: id}, _} = Games.find_similar_question_in_pool(g.id, e0)
      assert id == base_row.id

      assert Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [42]) == nil

      exp_row = pooled_q(g, [42])
      assert {%{id: id2}, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [42])
      assert id2 == exp_row.id
    end

    test "pool: unsorted query set matches the stored sorted set", %{g: g, e0: e0} do
      row = pooled_q(g, [3, 7])
      assert {%{id: id}, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [7, 3])
      assert id == row.id
    end

    test "find_user_duplicate scopes by set", %{g: g} do
      u = user()

      {:ok, _} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "exact repeat?",
          answer: "Yes.",
          expansion_ids: [42]
        })

      assert Games.find_user_duplicate(g.id, u.id, "exact repeat?", "exact repeat?") == nil

      assert {%{}, _} =
               Games.find_user_duplicate(g.id, u.id, "exact repeat?", "exact repeat?", [42])
    end

    test "find_user_similar scopes by set", %{g: g, e0: e0} do
      u = user()

      {:ok, q} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "similar?",
          answer: "Similar answer.",
          expansion_ids: []
        })

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [question_embedding: Pgvector.new(e0)]
      )

      assert {%{}, _} = Games.find_user_similar(g.id, u.id, e0)
      assert Games.find_user_similar(g.id, u.id, e0, expansion_ids: [42]) == nil
    end

    test "find_user_answer_duplicate scopes by set", %{g: g} do
      u = user()

      {:ok, prior} =
        Games.log_question(%{
          game_id: g.id,
          user_id: u.id,
          question: "worded one way",
          answer: "Identical ruling text.",
          expansion_ids: []
        })

      _ = prior

      assert Games.find_user_answer_duplicate(g.id, u.id, "Identical ruling text.", 0)
      assert Games.find_user_answer_duplicate(g.id, u.id, "Identical ruling text.", 0, [42]) == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: FAIL — pool test's `expansion_ids: [42]` lookup returns the base row (no scoping yet); arity errors on the two new positional params.

- [ ] **Step 3: Implement scoping in `lib/rule_maven/games.ex`**

`find_similar_question_in_pool/3`: read + sort the opt, add one `where`:

```elixir
  def find_similar_question_in_pool(game_id, question_embedding, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, pool_distance_threshold())
    expansion_ids = opts |> Keyword.get(:expansion_ids, []) |> Enum.sort()
    floor = RuleMaven.Games.Trust.trusted_floor()

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id,
          # An answer only serves asks made against the SAME expansion set —
          # expansions change rules, so a base-only answer can be wrong with
          # an expansion in play (and vice versa).
          where: q.expansion_ids == ^expansion_ids,
          ...existing wheres/order_by unchanged...
```

`find_user_duplicate` gains a 5th positional param (update the `@doc` and the nil-user head):

```elixir
  def find_user_duplicate(game_id, user_id, cleaned, raw, expansion_ids \\ [])
  def find_user_duplicate(_game_id, nil, _cleaned, _raw, _expansion_ids), do: nil

  def find_user_duplicate(game_id, user_id, cleaned, raw, expansion_ids) do
    cleaned = String.downcase(to_string(cleaned))
    raw = String.downcase(to_string(raw))
    expansion_ids = Enum.sort(expansion_ids)

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id,
          where: q.expansion_ids == ^expansion_ids,
          ...existing wheres unchanged...
```

`find_user_similar/4`: opt like the pool —

```elixir
    expansion_ids = opts |> Keyword.get(:expansion_ids, []) |> Enum.sort()
    ...
          where: q.expansion_ids == ^expansion_ids,
```

`find_user_answer_duplicate` gains a 5th positional param, same pattern as `find_user_duplicate` (default `[]`, nil-user head updated, sorted, one extra `where`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: PASS

- [ ] **Step 5: Run the neighbors that already exercise these functions**

Run: `mix test test/rule_maven/games_test.exs test/rule_maven/games_pool_invalidation_test.exs test/rule_maven/trust_test.exs 2>&1 | tee tmp/exp_neighbors.log`
Expected: PASS (defaults keep old call sites base-only).

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_expansion_cache_test.exs
git commit -m "feat: scope answer cache tiers by expansion set"
```

### Task 3: Thread the set through the ask flow

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`ask/5`, lines ~35–98)
- Modify: `lib/rule_maven/workers/ask_worker.ex` (line ~108, `find_user_answer_duplicate` call)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — both `Games.log_question` sites (lines ~705 and ~1094)
- Test: `test/rule_maven/llm_test.exs` pattern-following addition in `test/rule_maven/games_expansion_cache_test.exs`

**Interfaces:**
- Consumes: Task 2 signatures.
- Produces: every logged question carries `expansion_ids: Enum.sort(expansion_ids)`; `LLM.ask(game, question, expansion_ids, ...)` consults only same-set cache rows.

- [ ] **Step 1: Modify `LLM.ask/5`** (no clean unit seam without an LLM stub, so this step is implementation-first; the behavior test is Step 3)

In `lib/rule_maven/llm.ex`, at the top of `ask/5` add the sort, and pass the set into all three lookups:

```elixir
  def ask(game, question, expansion_ids \\ [], recent_context \\ [], opts \\ []) do
    skip_pool = Keyword.get(opts, :skip_pool, false)
    # Canonical sorted form — cache rows store and match this exact set.
    expansion_ids = Enum.sort(expansion_ids)
```

then:

```elixir
    pool_hit =
      !skip_pool && question_embedding &&
        RuleMaven.Games.find_similar_question_in_pool(game.id, question_embedding,
          expansion_ids: expansion_ids
        )

    user_exact =
      !skip_pool && user_id &&
        RuleMaven.Games.find_user_duplicate(game.id, user_id, match_text, question, expansion_ids)

    user_semantic =
      !skip_pool && user_id && question_embedding &&
        RuleMaven.Games.find_user_similar(game.id, user_id, question_embedding,
          expansion_ids: expansion_ids
        )
```

(`call_llm` already receives `expansion_ids`; no change there.)

- [ ] **Step 2: Modify AskWorker + show.ex log sites**

`lib/rule_maven/workers/ask_worker.ex` line ~108 — scope the answer-side dedup to the same set:

```elixir
            answer_dup =
              ql && !llm_result[:pool_hit] && !refused?(answer) &&
                Games.find_user_answer_duplicate(
                  game_id,
                  user_id,
                  answer,
                  question_log_id,
                  Enum.sort(expansion_ids)
                )
```

`lib/rule_maven_web/live/game_live/show.ex` — both `Games.log_question` calls (the ask at ~705 and the retry at ~1094) gain one attr:

```elixir
                  case Games.log_question(%{
                         game_id: game.id,
                         question: question,
                         answer: "Thinking...",
                         user_id: socket.assigns.current_user.id,
                         visibility: visibility,
                         expansion_ids: Enum.sort(expansion_ids)
                       }) do
```

(Both sites already compute `expansion_ids = Map.keys(included)` a few lines above.)

- [ ] **Step 3: Write the behavior test**

Append to `test/rule_maven/games_expansion_cache_test.exs`:

```elixir
  describe "LLM.ask serves cache per expansion set" do
    test "a pooled base-only answer is not served to an expansion ask" do
      g = game()
      pooled_q(g, [])

      # Base ask (embedding fails in test env → Embed.embed returns error →
      # question_embedding nil → pool skipped). So instead call the lookup the
      # way ask/5 now does, proving the wiring end-to-end at the Games layer:
      e0 = [1.0 | List.duplicate(0.0, 767)]
      assert {_, _} = Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [])
      assert Games.find_similar_question_in_pool(g.id, e0, expansion_ids: [99]) == nil
    end
  end
```

Note for the implementer: `LLM.ask` itself needs a live embedding + LLM to integration-test; existing suite (`llm_test.exs`) stubs at the `Games` layer the same way. The compile-time guarantee that `ask/5` passes the set is the code in Step 1; grep-verify:

Run: `rg -n "expansion_ids" lib/rule_maven/llm.ex lib/rule_maven/workers/ask_worker.ex lib/rule_maven_web/live/game_live/show.ex`
Expected: the three lookup calls, the AskWorker dedup call, and both `log_question` attrs all reference `expansion_ids`.

- [ ] **Step 4: Run tests + compile**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs test/rule_maven/llm_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: PASS, no warnings about `LLM.ask` arity.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex lib/rule_maven/workers/ask_worker.ex lib/rule_maven_web/live/game_live/show.ex test/rule_maven/games_expansion_cache_test.exs
git commit -m "feat: thread expansion set through ask flow and cache lookups"
```

### Task 4: Expansion rulebook changes invalidate base-game answers

**Files:**
- Modify: `lib/rule_maven/games.ex` — `invalidate_pool/1` (line ~965)
- Test: `test/rule_maven/games_expansion_cache_test.exs`

**Interfaces:**
- Consumes: `expansion_ids` column (Task 1).
- Produces: `invalidate_pool(game_id)` also demotes/stales/flags rows on OTHER games whose `expansion_ids` contain `game_id`.

- [ ] **Step 1: Write the failing test**

```elixir
  describe "invalidate_pool/1 reaches answers that used the changed expansion" do
    test "staling an expansion stales base-game rows that included it" do
      base = game("Base")
      exp = game("Exp")

      with_exp = pooled_q(base, [exp.id])
      without_exp = pooled_q(base, [])

      Games.invalidate_pool(exp.id)

      assert Repo.get!(QuestionLog, with_exp.id).stale
      assert Repo.get!(QuestionLog, with_exp.id).pooled == false
      refute Repo.get!(QuestionLog, without_exp.id).stale
      assert Repo.get!(QuestionLog, without_exp.id).pooled
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: FAIL — `with_exp` row untouched (its `game_id` is the base, not the changed expansion).

- [ ] **Step 3: Widen the three `update_all` filters**

In `invalidate_pool/1`, each of the three queries currently filters `q.game_id == ^game_id`. Replace that clause in all three with membership-or-owner (and extend the `@doc` to say expansion content changes invalidate the base-game answers that used them):

```elixir
        from(q in QuestionLog,
          where:
            (q.game_id == ^game_id or fragment("? = ANY(?)", ^game_id, q.expansion_ids)) and
              q.pooled == true
        ),
```

(same `or fragment(...)` addition for the `stale == false` and the community `needs_review == false` queries).

- [ ] **Step 4: Run tests to verify pass + neighbors**

Run: `mix test test/rule_maven/games_expansion_cache_test.exs test/rule_maven/games_pool_invalidation_test.exs 2>&1 | tee tmp/exp_cache.log`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_expansion_cache_test.exs
git commit -m "feat: expansion rulebook changes invalidate base-game cached answers"
```

---

## Feature B — Persisted expansion selection

### Task 5: `expansion_selections` table + Games API

**Files:**
- Create: `priv/repo/migrations/20260703171000_create_expansion_selections.exs`
- Create: `lib/rule_maven/games/expansion_selection.ex`
- Modify: `lib/rule_maven/games.ex` (new section near the expansion helpers, ~line 260)
- Test: `test/rule_maven/games_expansion_selection_test.exs` (new file)

**Interfaces:**
- Produces (Task 6 + Task 11 consume):
  - `Games.put_expansion_selection(user_id, base_game_id, expansion_ids) :: :ok` — upsert, stores sorted
  - `Games.get_expansion_selection(user_id, base_game_id) :: [integer] | nil` — nil = never chosen
  - `Games.effective_expansion_ids(user_id, %Game{} = base_game) :: [integer]` — explicit selection if present, else collection-derived default; always intersected with `expansions_with_documents` ids, sorted.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule RuleMaven.GamesExpansionSelectionTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}

  defp game(name) do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  defp user do
    Repo.insert!(%RuleMaven.Users.User{
      username: "sel_user_#{System.unique_integer([:positive])}",
      email: "sel#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  # A published-doc expansion linked to base.
  defp expansion_for(base) do
    exp = game("Exp")
    Games.link_expansion(exp.id, base.id)

    {:ok, doc} = Games.create_document(%{game_id: exp.id, label: "R", full_text: "rules text"})
    {:ok, _} = Games.update_document(doc, %{status: "published"})
    exp
  end

  test "put/get round-trips sorted; get is nil before any put" do
    u = user()
    base = game("Base")

    assert Games.get_expansion_selection(u.id, base.id) == nil

    :ok = Games.put_expansion_selection(u.id, base.id, [9, 4])
    assert Games.get_expansion_selection(u.id, base.id) == [4, 9]

    # Upsert replaces.
    :ok = Games.put_expansion_selection(u.id, base.id, [])
    assert Games.get_expansion_selection(u.id, base.id) == []
  end

  test "effective_expansion_ids: explicit selection wins, filtered to available" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)

    :ok = Games.put_expansion_selection(u.id, base.id, [exp.id, 999_999])
    assert Games.effective_expansion_ids(u.id, base) == [exp.id]
  end

  test "effective_expansion_ids: defaults from user's collection when never chosen" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)
    _unowned = expansion_for(base)

    Repo.insert!(%RuleMaven.Games.UserCollection{user_id: u.id, game_id: exp.id})

    assert Games.effective_expansion_ids(u.id, base) == [exp.id]
  end

  test "effective_expansion_ids: empty explicit choice beats collection default" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)
    Repo.insert!(%RuleMaven.Games.UserCollection{user_id: u.id, game_id: exp.id})

    :ok = Games.put_expansion_selection(u.id, base.id, [])
    assert Games.effective_expansion_ids(u.id, base) == []
  end
end
```

Note: if `Games.update_document/2` doesn't exist under that name, use the existing document-update function (grep `def update_document` / `def change_document`); the point is a `status: "published"` doc on the expansion.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_expansion_selection_test.exs 2>&1 | tee tmp/exp_sel.log`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Migration**

```elixir
defmodule RuleMaven.Repo.Migrations.CreateExpansionSelections do
  use Ecto.Migration

  def change do
    create table(:expansion_selections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      # Sorted ascending; [] is a meaningful explicit "base only" choice.
      add :expansion_ids, {:array, :integer}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:expansion_selections, [:user_id, :game_id])
  end
end
```

Run: `mix ecto.migrate`

- [ ] **Step 4: Schema**

`lib/rule_maven/games/expansion_selection.ex`:

```elixir
defmodule RuleMaven.Games.ExpansionSelection do
  @moduledoc """
  A user's remembered per-base-game expansion choice. One row per
  {user, base game}; `expansion_ids` is the sorted set they play with.
  Row absent = never chosen (UI then defaults from the user's collection);
  `[]` = an explicit "base game only" choice.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "expansion_selections" do
    field :expansion_ids, {:array, :integer}, default: []
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(sel, attrs) do
    sel
    |> cast(attrs, [:user_id, :game_id, :expansion_ids])
    |> validate_required([:user_id, :game_id])
    |> unique_constraint([:user_id, :game_id])
  end
end
```

- [ ] **Step 5: Games API**

In `lib/rule_maven/games.ex`, after `base_game_for/1` (~line 272), alias `ExpansionSelection` alongside the existing aliases, then:

```elixir
  ## Expansion selection (per user, per base game) -----------------------------

  @doc """
  Remember the expansion set a user plays `base_game_id` with. Upsert; stores
  the set sorted. `[]` is a meaningful "base only" choice (distinct from no
  row, which means "never chosen" and lets the collection-derived default
  apply).
  """
  def put_expansion_selection(user_id, base_game_id, expansion_ids) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      ExpansionSelection,
      [
        %{
          user_id: user_id,
          game_id: base_game_id,
          expansion_ids: Enum.sort(expansion_ids),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:expansion_ids, :updated_at]},
      conflict_target: [:user_id, :game_id]
    )

    :ok
  end

  @doc "The user's stored expansion set for a base game, or nil when never chosen."
  def get_expansion_selection(user_id, base_game_id) do
    Repo.one(
      from s in ExpansionSelection,
        where: s.user_id == ^user_id and s.game_id == ^base_game_id,
        select: s.expansion_ids
    )
  end

  @doc """
  The expansion set to preselect for a user on a base game's page: their
  explicit stored choice if any, else the expansions in their collection.
  Always filtered to expansions that actually have published documents (a
  stored id whose docs were unpublished, or an owned expansion with no
  rulebook, silently drops out), sorted ascending.
  """
  def effective_expansion_ids(user_id, %Game{} = base_game) do
    available = base_game |> expansions_with_documents() |> MapSet.new(& &1.id)

    chosen =
      case get_expansion_selection(user_id, base_game.id) do
        nil ->
          Repo.all(
            from uc in UserCollection,
              where: uc.user_id == ^user_id and uc.game_id in ^MapSet.to_list(available),
              select: uc.game_id
          )

        ids ->
          ids
      end

    chosen |> Enum.filter(&MapSet.member?(available, &1)) |> Enum.sort()
  end
```

(`UserCollection` is already aliased in games.ex; verify with `rg -n "alias.*UserCollection" lib/rule_maven/games.ex` and add if missing.)

- [ ] **Step 6: Run tests to verify pass**

Run: `mix test test/rule_maven/games_expansion_selection_test.exs 2>&1 | tee tmp/exp_sel.log`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260703171000_create_expansion_selections.exs lib/rule_maven/games/expansion_selection.ex lib/rule_maven/games.ex test/rule_maven/games_expansion_selection_test.exs
git commit -m "feat: persist per-user expansion selection with collection default"
```

### Task 6: Show page seeds + persists the selection

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — mount assigns (~line 39), `do_handle_params` (~line 183), `toggle_expansion` (~line 461)

**Interfaces:**
- Consumes: `Games.effective_expansion_ids/2`, `Games.put_expansion_selection/3` (Task 5).

- [ ] **Step 1: Seed on first `handle_params`**

In `mount`'s assign block add `expansions_seeded: false,` next to `included_expansions: %{}`.

In `do_handle_params`, replace the pass-through assign (line ~193):

```elixir
        included_expansions: socket.assigns.included_expansions,
```

with a seeded value computed just above the big `assign` (after `expansions = Games.expansions_with_documents(game)`):

```elixir
    # First load of this game: restore the user's remembered expansion set
    # (or default from their collection). Later handle_params runs (thread
    # nav, ?t=) keep the in-session toggles.
    included_expansions =
      if socket.assigns.expansions_seeded do
        socket.assigns.included_expansions
      else
        socket.assigns.current_user.id
        |> Games.effective_expansion_ids(game)
        |> Map.new(&{&1, true})
      end
```

and in the assign block:

```elixir
        included_expansions: included_expansions,
        expansions_seeded: true,
```

- [ ] **Step 2: Persist on toggle**

In `handle_event("toggle_expansion", ...)` before the `{:noreply, ...}`:

```elixir
    Games.put_expansion_selection(
      socket.assigns.current_user.id,
      socket.assigns.game.id,
      Map.keys(included)
    )

    {:noreply, assign(socket, included_expansions: included)}
```

- [ ] **Step 3: Compile + targeted tests**

Run: `mix compile --warnings-as-errors && mix test test/rule_maven_web/live 2>&1 | tee tmp/exp_sel_live.log`
Expected: compiles clean; existing live tests PASS.

- [ ] **Step 4: Manual verify (dev server)**

Open a game with expansions, toggle one on, reload the page → toggle still on. Toggle off, reload → off (explicit empty persists). Ask a question with the expansion on, then check the row: `RuleMaven.Repo.one(from q in RuleMaven.Games.QuestionLog, order_by: [desc: q.id], limit: 1, select: q.expansion_ids)` shows the id.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat: seed and persist expansion selection on game page"
```

---

## Feature C — Per-expansion deltas (setup + rule changes)

### Task 7: Prompts registry entries

**Files:**
- Modify: `lib/rule_maven/prompts.ex` — module attrs near `@setup_generate` (~line 394), registry entries near the `setup_generate` entry (~line 802)
- Test: `test/rule_maven/settings_test.exs`-style check appended to `test/rule_maven/expansion_delta_test.exs` (created here, extended in Task 8)

**Interfaces:**
- Produces: `Prompts.template("expansion_delta_system")`, `Prompts.render("expansion_delta", %{game_name: ..., rulebook: ...})`.

- [ ] **Step 1: Write the failing test**

`test/rule_maven/expansion_delta_test.exs`:

```elixir
defmodule RuleMaven.ExpansionDeltaTest do
  use RuleMaven.DataCase

  test "delta prompts are registered with their vars" do
    assert RuleMaven.Prompts.template("expansion_delta_system") =~ "expansion"

    rendered =
      RuleMaven.Prompts.render("expansion_delta", %{game_name: "Wingfans", rulebook: "TEXT"})

    assert rendered =~ "Wingfans"
    assert rendered =~ "TEXT"
    refute rendered =~ "{{"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/expansion_delta_test.exs 2>&1 | tee tmp/delta.log`
Expected: FAIL — unknown prompt key.

- [ ] **Step 3: Add the templates + registry entries**

Module attrs (after `@setup_generate`):

```elixir
  # ── Expansion delta: what an expansion changes about its base game. ──
  @expansion_delta_system "You extract what a board game expansion adds or changes, using only its rulebook text. Never invent rules."

  # Vars: game_name, rulebook
  @expansion_delta """
  This rulebook text is from "{{game_name}}", an EXPANSION for a board game.
  Using only this text, list what the expansion adds or changes, in three
  sections. Every item one line, prefixed "- ".

  COMPONENTS:
  (new components players must gather during setup)

  SETUP:
  (setup steps this expansion adds or changes; each a short imperative,
  optionally followed by " — " and a brief clarifying sentence)

  RULE CHANGES:
  (base-game rules this expansion adds, changes, or overrides; one short,
  self-contained bullet each — include the numbers)

  If a section has nothing, output its header with no bullets.

  RULEBOOK:
  {{rulebook}}
  """
```

Registry entries (after the `setup_generate` entry):

```elixir
    %{
      key: "expansion_delta_system",
      group: "Expansion delta",
      label: "Expansion delta — system",
      description: "System primer for the expansion-changes extractor.",
      vars: [],
      default: @expansion_delta_system
    },
    %{
      key: "expansion_delta",
      group: "Expansion delta",
      label: "Expansion delta — generate",
      description:
        "Extracts the components / setup changes / rule changes an expansion makes, from its own rulebook.",
      vars: ~w(game_name rulebook),
      default: @expansion_delta
    },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/expansion_delta_test.exs 2>&1 | tee tmp/delta.log`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/prompts.ex test/rule_maven/expansion_delta_test.exs
git commit -m "feat: expansion delta prompts in registry"
```

### Task 8: `RuleMaven.ExpansionDelta` module

**Files:**
- Create: `lib/rule_maven/expansion_delta.ex`
- Test: `test/rule_maven/expansion_delta_test.exs`

**Interfaces:**
- Consumes: Prompts keys (Task 7), `Games.rulebook_text/1`, `LLM.chat/3` (same call shape as `Setup.generate_content/1`), `Settings`.
- Produces (Tasks 9–11 consume):
  - `ExpansionDelta.generate_async(game) :: :ok` — seeds Settings state machine, enqueues worker
  - `ExpansionDelta.status(game_id) :: nil | "generating" | "done" | "error"`
  - `ExpansionDelta.stored(game_id) :: nil | %{"components" => [String.t()], "setup" => [%{"title","detail"}], "rules" => [String.t()]}`
  - `ExpansionDelta.stored_error(game_id)`, `ExpansionDelta.clear(game_id)`
  - `ExpansionDelta.topic(game_id) :: "delta:#{game_id}"`
  - `ExpansionDelta.generate_content(game) :: {:ok, json} | {:error, reason}`
  - `ExpansionDelta.parse_sections(text)` (`@doc false`, for tests)

- [ ] **Step 1: Write the failing parser tests**

Append to `test/rule_maven/expansion_delta_test.exs`:

```elixir
  describe "parse_sections/1" do
    test "parses the three labelled sections" do
      out = """
      COMPONENTS:
      - 15 fan tokens
      - 1 gale board

      SETUP:
      - Place the gale board — next to the main board
      - Shuffle fan tokens

      RULE CHANGES:
      - Draw 3 cards instead of 2 at the start of each round
      """

      assert %{
               "components" => ["15 fan tokens", "1 gale board"],
               "setup" => [
                 %{"title" => "Place the gale board", "detail" => "next to the main board"},
                 %{"title" => "Shuffle fan tokens", "detail" => ""}
               ],
               "rules" => ["Draw 3 cards instead of 2 at the start of each round"]
             } = RuleMaven.ExpansionDelta.parse_sections(out)
    end

    test "tolerates markdown headers and empty sections" do
      out = """
      **Components:**

      ## Setup
      - Add the new deck

      **Rule changes:**
      """

      assert %{"components" => [], "setup" => [%{"title" => "Add the new deck"}], "rules" => []} =
               RuleMaven.ExpansionDelta.parse_sections(out)
    end

    test "nil when nothing parses" do
      assert RuleMaven.ExpansionDelta.parse_sections("no sections here") == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/expansion_delta_test.exs 2>&1 | tee tmp/delta.log`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the module**

`lib/rule_maven/expansion_delta.ex` — mirrors `RuleMaven.Setup`'s Settings state machine and parser style (see `lib/rule_maven/setup.ex`); the parser handles three sections:

```elixir
defmodule RuleMaven.ExpansionDelta do
  @moduledoc """
  Generates a per-expansion "what this expansion changes" delta from the
  expansion's own rulebook: new components, setup changes, and rule changes.
  Generated once per expansion (durable Oban worker) and composed at display
  time into the BASE game's setup checklist and cheat sheet for whichever
  expansion set the viewer selected — linear cost in the number of
  expansions, never per-combo.

  Mirrors the Setup/CheatSheet Settings state-machine pattern; keys are
  `delta_*_<expansion_game_id>`. Stored content is JSON:
  `%{"components" => [string], "setup" => [%{"title","detail"}],
  "rules" => [string]}`.
  """

  alias RuleMaven.{Games, Settings, LLM}

  @doc "Seeds the state machine and enqueues durable generation."
  def generate_async(game) do
    game_id = game.id
    Settings.put("delta_status_#{game_id}", "generating")
    Settings.put("delta_content_#{game_id}", nil)
    Settings.put("delta_error_#{game_id}", nil)

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id}
      |> RuleMaven.Workers.ExpansionDeltaWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  def topic(game_id), do: "delta:#{game_id}"

  def status(game_id), do: Settings.get("delta_status_#{game_id}")
  def stored_error(game_id), do: Settings.get("delta_error_#{game_id}")

  @doc "Parsed delta `%{components, setup, rules}` or nil."
  def stored(game_id) do
    case Settings.get("delta_content_#{game_id}") do
      nil -> nil
      json -> decode(json)
    end
  end

  def clear(game_id) do
    Settings.put("delta_status_#{game_id}", nil)
    Settings.put("delta_content_#{game_id}", nil)
    Settings.put("delta_error_#{game_id}", nil)
  end

  @doc """
  Generates the delta content from the expansion's own rulebook. Returns
  `{:ok, json_string}` or `{:error, reason}`.
  """
  def generate_content(game) do
    text = Games.rulebook_text(game)

    if String.trim(text) == "" do
      {:error, "No rulebook text available for #{game.name}"}
    else
      # Changes cluster early (setup + "what's new") but rule overrides can sit
      # deeper than base-game setup does — give it more room than Setup's 16k.
      source = String.slice(text, 0, 24_000)

      system = RuleMaven.Prompts.template("expansion_delta_system")

      prompt =
        RuleMaven.Prompts.render("expansion_delta", %{game_name: game.name, rulebook: source})

      case LLM.chat(prompt, "expansion_delta_#{game.name}",
             operation: "expansion_delta",
             game_id: game.id,
             system: system,
             max_tokens: 8000
           ) do
        {:ok, content} ->
          case parse_sections(content) do
            nil -> {:error, "Could not parse the expansion delta. Please retry."}
            map -> {:ok, Jason.encode!(map)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Parse the model's three-section bullet text into the stored shape. Returns
  # nil when no section yields any items. Public only for tests.
  @doc false
  def parse_sections(content) do
    lines = String.split(to_string(content), ~r/\r?\n/)

    {comps, setup, rules, _section} =
      Enum.reduce(lines, {[], [], [], nil}, fn line, {comps, setup, rules, section} ->
        trimmed = String.trim(line)
        header = normalize_header(trimmed)
        item = trimmed |> bullet_text() |> strip_md()

        cond do
          is_nil(item) and String.starts_with?(header, "component") ->
            {comps, setup, rules, :components}

          is_nil(item) and String.starts_with?(header, "rule") ->
            {comps, setup, rules, :rules}

          is_nil(item) and
              (String.starts_with?(header, "step") or String.contains?(header, "setup")) ->
            {comps, setup, rules, :setup}

          item == nil ->
            {comps, setup, rules, section}

          section == :components ->
            {[item | comps], setup, rules, section}

          section == :setup ->
            {comps, [parse_step(item) | setup], rules, section}

          section == :rules ->
            {comps, setup, [item | rules], section}

          true ->
            {comps, setup, rules, section}
        end
      end)

    comps = Enum.reverse(comps)
    setup = setup |> Enum.reverse() |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
    rules = Enum.reverse(rules)

    if comps == [] and setup == [] and rules == [],
      do: nil,
      else: %{"components" => comps, "setup" => setup, "rules" => rules}
  end

  # ── shared shapes with Setup's parser ──

  defp normalize_header(line) do
    line
    |> String.downcase()
    |> String.replace(~r/[*#_`]/, "")
    |> String.trim()
    |> String.trim_trailing(":")
    |> String.trim()
  end

  defp strip_md(nil), do: nil
  defp strip_md(text), do: text |> String.replace(~r/[*_`]/, "") |> String.trim()

  defp bullet_text(line) do
    case Regex.run(~r/^\s*(?:[-*•]|\d+[.)])\s+(.*\S)\s*$/, line) do
      [_, text] -> text
      _ -> nil
    end
  end

  defp parse_step(item) do
    case Regex.split(~r/\s+[—–-]\s+|:\s+/u, item, parts: 2) do
      [title, detail] -> %{"title" => String.trim(title), "detail" => String.trim(detail)}
      [title] -> %{"title" => String.trim(title), "detail" => ""}
    end
  end

  # Tolerant decode: strips fences/prose around the JSON object.
  defp decode(content) do
    with json when is_binary(json) <- extract_json(content),
         {:ok, %{} = map} <- Jason.decode(json) do
      %{
        "components" => string_list(map["components"]),
        "setup" => step_list(map["setup"]),
        "rules" => string_list(map["rules"])
      }
    else
      _ -> nil
    end
  end

  defp extract_json(content) do
    case Regex.run(~r/\{.*\}/s, to_string(content)) do
      [json] -> json
      _ -> nil
    end
  end

  defp string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp string_list(_), do: []

  defp step_list(v) when is_list(v) do
    v
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn s -> %{"title" => to_string(s["title"]), "detail" => to_string(s["detail"])} end)
    |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
  end

  defp step_list(_), do: []
end
```

Design note: no second-pass fact-check in v1 (Setup has one). The delta reads the expansion's own rulebook directly; add a verify pass later if hallucinated rule bullets show up.

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/rule_maven/expansion_delta_test.exs 2>&1 | tee tmp/delta.log`
Expected: PASS (worker module referenced only inside the non-test Oban branch, so it can not-exist yet).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/expansion_delta.ex test/rule_maven/expansion_delta_test.exs
git commit -m "feat: ExpansionDelta module — extract what an expansion changes"
```

### Task 9: Worker + readiness enrichment hook

**Files:**
- Create: `lib/rule_maven/workers/expansion_delta_worker.ex`
- Modify: `lib/rule_maven/readiness.ex` — `ensure_enrichments/1` (~line 394)
- Test: `test/rule_maven/expansion_delta_test.exs`

**Interfaces:**
- Consumes: `ExpansionDelta.generate_content/1` + Settings keys (Task 8), `Jobs.start_run/finish_run`, `Games.expansion?/1`.
- Produces: `ExpansionDeltaWorker.enqueue(game_id)`; broadcast `{:delta_done, game_id}` on `ExpansionDelta.topic(game_id)`; expansions get a delta automatically when their prepare pipeline finishes.

- [ ] **Step 1: Write the failing test**

```elixir
  describe "readiness kicks delta generation for expansions" do
    test "ensure_enrichments seeds the delta state machine for an expansion, not a base game" do
      {:ok, base} = RuleMaven.Games.create_game(%{name: "DeltaBase #{System.unique_integer([:positive])}"})
      {:ok, exp} = RuleMaven.Games.create_game(%{name: "DeltaExp #{System.unique_integer([:positive])}"})
      RuleMaven.Games.link_expansion(exp.id, base.id)

      # drive/1 reaches ensure_enrichments only at :done; call the enrichment
      # kick directly via a full drive on a game with everything missing is
      # complex — instead assert the public seam: generate_async seeds state,
      # and Readiness.ensure_enrichments/1 (exposed for this test) enqueues for
      # expansions only.
      RuleMaven.Readiness.ensure_enrichments(exp)
      assert RuleMaven.ExpansionDelta.status(exp.id) == "generating"

      RuleMaven.Readiness.ensure_enrichments(base)
      assert RuleMaven.ExpansionDelta.status(base.id) == nil
    end
  end
```

Note: `ensure_enrichments/1` is currently `defp`. Make it public with `@doc false` (the test seam; `drive/1` remains the production caller).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/expansion_delta_test.exs 2>&1 | tee tmp/delta.log`
Expected: FAIL — `ensure_enrichments` private / delta status nil.

- [ ] **Step 3: Implement worker**

`lib/rule_maven/workers/expansion_delta_worker.ex` (mirror of `SetupChecklistWorker`):

```elixir
defmodule RuleMaven.Workers.ExpansionDeltaWorker do
  @moduledoc """
  Durable expansion-delta generation. Runs the LLM extraction, writes the
  result into the `delta_*_<game_id>` Settings state machine, and broadcasts
  `{:delta_done, game_id}` on `ExpansionDelta.topic/1`.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings, ExpansionDelta}

  def enqueue(game_id) do
    %{game_id: game_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("expansion_delta", {"game", game_id}, "Expansion delta — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Extracting what this expansion changes…")

    result =
      try do
        ExpansionDelta.generate_content(game)
      rescue
        e -> {:error, "Unexpected error: #{Exception.message(e)}"}
      end

    case result do
      {:ok, json} ->
        Settings.put("delta_status_#{game_id}", "done")
        Settings.put("delta_content_#{game_id}", json)
        Jobs.finish_run(run, "done", "Delta generated (#{item_count(json)} items).")

      {:error, reason} ->
        Settings.put("delta_status_#{game_id}", "error")
        Settings.put("delta_error_#{game_id}", reason)
        Jobs.finish_run(run, "failed", reason)
    end

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, ExpansionDelta.topic(game_id), {:delta_done, game_id})
    :ok
  end

  defp item_count(json) do
    case Jason.decode(json) do
      {:ok, %{"components" => c, "setup" => s, "rules" => r}} ->
        length(c) + length(s) + length(r)

      _ ->
        0
    end
  end
end
```

- [ ] **Step 4: Hook into readiness**

In `lib/rule_maven/readiness.ex`, change `defp ensure_enrichments(%Game{} = game) do` to `def ensure_enrichments(%Game{} = game) do` with `@doc false` above it, and inside the `unless Settings.get(key) == "on"` block add:

```elixir
      # Expansions additionally get a "what this expansion changes" delta,
      # composed into their base games' setup checklist + cheat sheet.
      safe(fn ->
        if Games.expansion?(game.id), do: RuleMaven.ExpansionDelta.generate_async(game)
      end)
```

- [ ] **Step 5: Run tests to verify pass + readiness neighbors**

Run: `mix test test/rule_maven/expansion_delta_test.exs test/rule_maven/readiness_test.exs 2>&1 | tee tmp/delta.log`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/workers/expansion_delta_worker.ex lib/rule_maven/readiness.ex test/rule_maven/expansion_delta_test.exs
git commit -m "feat: durable expansion-delta worker, kicked by readiness enrichment"
```

### Task 10: Delta sections in the setup checklist card

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — `do_handle_params` assigns, `toggle_expansion`, setup-checklist heex (~lines 1930–2015), plus a `handle_info({:delta_done, _}, ...)` clause near the `{:setup_done, ...}` clause (~line 1334)

**Interfaces:**
- Consumes: `ExpansionDelta.stored/1`, `ExpansionDelta.topic/1` (Task 8), `included_expansions` (Task 6).
- Produces: assign `expansion_deltas :: [{%Game{}, delta_map}]` for the currently-included expansions that have a stored delta.

- [ ] **Step 1: Load deltas + subscribe**

Add a private helper near `load_setup`:

```elixir
  # Deltas for the currently-included expansions that have one stored, in
  # expansion-name order (the `expansions` assign is already name-sorted).
  defp load_expansion_deltas(expansions, included) do
    expansions
    |> Enum.filter(&Map.get(included, &1.id))
    |> Enum.flat_map(fn exp ->
      case RuleMaven.ExpansionDelta.stored(exp.id) do
        nil -> []
        delta -> [{exp, delta}]
      end
    end)
  end
```

In `do_handle_params`: subscribe (inside the `if connected?` block) to each available expansion's delta topic so a finishing generation live-updates the card:

```elixir
      for exp <- Games.expansions_with_documents(game) do
        Phoenix.PubSub.subscribe(RuleMaven.PubSub, RuleMaven.ExpansionDelta.topic(exp.id))
      end
```

(Reuse the already-computed `expansions` list if ordering allows; otherwise call once and reuse for both.) Then in the assign block:

```elixir
        expansion_deltas: load_expansion_deltas(expansions, included_expansions),
```

In `toggle_expansion`, recompute alongside the persist call:

```elixir
    {:noreply,
     assign(socket,
       included_expansions: included,
       expansion_deltas: load_expansion_deltas(socket.assigns.expansions, included)
     )}
```

Add the pubsub clause next to `handle_info({:setup_done, ...})`:

```elixir
  def handle_info({:delta_done, _game_id}, socket) do
    {:noreply,
     assign(socket,
       expansion_deltas:
         load_expansion_deltas(socket.assigns.expansions, socket.assigns.included_expansions)
     )}
  end
```

Also add `expansion_deltas: []` to the mount assigns so the dead render is safe.

- [ ] **Step 2: Render delta sections**

**DRY requirement:** the base checklist's Gather/Steps item markup and the delta sections below share one item shape. Extract ONE private function component in show.ex, e.g. `checklist_item(assigns)` taking `key`, `checked`, `title`, `detail` (detail nil for plain component items), and use it for the base `c-`/`s-` items AND the delta `xc-`/`xs-` items — do not paste the button markup twice. The heex below shows the required rendering/keys; realize it through the shared component.

In the setup-checklist heex, two changes.

The `total` count (line ~1932) becomes:

```elixir
                  <% delta_total =
                    Enum.reduce(@expansion_deltas, 0, fn {_e, d}, acc ->
                      acc + length(d["components"]) + length(d["setup"])
                    end) %>
                  <% total =
                    length(@setup_checklist["components"]) + length(@setup_checklist["setup"]) +
                      delta_total %>
```

After the base `Steps` block (after the `<% end %>` at line ~2008), insert per-expansion sections. Checkbox keys are namespaced by expansion id so they survive re-orders (`xc-`/`xs-` prefixes vs the base `c-`/`s-`):

```heex
                    <%= for {exp, delta} <- @expansion_deltas do %>
                      <div style="font-size:0.66rem;font-weight:700;text-transform:uppercase;color:var(--accent);margin:0.8rem 0 0.3rem">
                        ➕ {exp.name}
                      </div>
                      <%= for {item, i} <- Enum.with_index(delta["components"]) do %>
                        <% key = "xc-#{exp.id}-#{i}" %>
                        <% checked = MapSet.member?(@checklist_done, key) %>
                        <button
                          type="button"
                          phx-click="toggle_step"
                          phx-value-key={key}
                          style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:0.2rem 0;font-size:0.82rem;line-height:1.4;color:#{if checked, do: "var(--text-muted)", else: "var(--text)"}"}
                        >
                          <span aria-hidden="true" style="flex-shrink:0">
                            {if checked, do: "☑️", else: "⬜"}
                          </span>
                          <span style={"flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere;#{if checked, do: "text-decoration:line-through", else: ""}"}>
                            {item}
                          </span>
                        </button>
                      <% end %>
                      <%= for {step, i} <- Enum.with_index(delta["setup"]) do %>
                        <% key = "xs-#{exp.id}-#{i}" %>
                        <% checked = MapSet.member?(@checklist_done, key) %>
                        <button
                          type="button"
                          phx-click="toggle_step"
                          phx-value-key={key}
                          style={"display:flex;gap:0.5rem;align-items:flex-start;width:100%;text-align:left;background:none;border:none;cursor:pointer;padding:0.3rem 0;font-size:0.82rem;line-height:1.4;color:#{if checked, do: "var(--text-muted)", else: "var(--text)"}"}
                        >
                          <span aria-hidden="true" style="flex-shrink:0">
                            {if checked, do: "☑️", else: "⬜"}
                          </span>
                          <span style="flex:1;min-width:0;white-space:normal;overflow-wrap:anywhere">
                            <span style={"font-weight:600;#{if checked, do: "text-decoration:line-through", else: ""}"}>
                              {step["title"]}
                            </span>
                            <%= if step["detail"] not in [nil, "", "nil"] do %>
                              <span style="display:block;font-size:0.74rem;color:var(--text-muted)">
                                {step["detail"]}
                              </span>
                            <% end %>
                          </span>
                        </button>
                      <% end %>
                    <% end %>
```

- [ ] **Step 3: Compile + live tests**

Run: `mix compile --warnings-as-errors && mix test test/rule_maven_web/live 2>&1 | tee tmp/delta_live.log`
Expected: clean compile, live tests PASS.

- [ ] **Step 4: Manual verify (dev server)**

Seed a delta by hand for a linked expansion, then check the card renders it only while that expansion is toggled on:

```elixir
RuleMaven.Settings.put("delta_status_#{exp_id}", "done")
RuleMaven.Settings.put("delta_content_#{exp_id}", Jason.encode!(%{
  "components" => ["5 gale tokens"],
  "setup" => [%{"title" => "Place the gale board", "detail" => "next to the main board"}],
  "rules" => ["Draw 3 cards instead of 2"]
}))
```

Toggle the expansion on → "➕ <name>" section appears with 2 checkable items and the done-counter includes them; toggle off → section gone.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat: expansion delta sections in setup checklist"
```

### Task 11: Cheat sheet page appends the selection's rule changes

**Files:**
- Modify: `lib/rule_maven_web/controllers/cheat_sheet_controller.ex` — `serve_active_cheatsheet/2`
- Test: `test/rule_maven_web/` controller test if a pattern exists (grep `cheat_sheet_controller_test`); else manual verify

**Interfaces:**
- Consumes: `Games.effective_expansion_ids/2` (Task 5), `ExpansionDelta.stored/1` (Task 8), `Games.expansions_with_documents/1`.
- Produces: cheat sheet HTML with one appended markdown section per selected expansion that has a delta.

- [ ] **Step 1: Implement**

In `serve_active_cheatsheet/2`, append delta markdown before serving:

```elixir
  defp serve_active_cheatsheet(conn, game) do
    docs = Games.list_documents(game)

    content =
      Enum.find_value(docs, fn doc ->
        active = CheatSheet.active_version(doc.id)
        if active, do: serve_content(conn, game.name, active.content <> delta_markdown(conn, game))
      end)
    ...
```

and add:

```elixir
  # Appends a "what changes" section per expansion the viewer plays with (their
  # persisted selection; base-only or no deltas → empty string). Versioned
  # cheat sheets (show_version) stay pristine — deltas only decorate the
  # active sheet.
  defp delta_markdown(conn, game) do
    user = conn.assigns[:current_user]
    selected = if user, do: Games.effective_expansion_ids(user.id, game), else: []

    if selected == [] do
      ""
    else
      by_id = game |> Games.expansions_with_documents() |> Map.new(&{&1.id, &1})

      sections =
        selected
        |> Enum.flat_map(fn id ->
          with %{} = exp <- by_id[id],
               %{"rules" => rules, "setup" => setup} when rules != [] or setup != [] <-
                 RuleMaven.ExpansionDelta.stored(id) do
            bullets =
              Enum.map(rules, &"- #{&1}") ++
                Enum.map(setup, fn s ->
                  detail = if s["detail"] in [nil, ""], do: "", else: " — #{s["detail"]}"
                  "- *Setup:* #{s["title"]}#{detail}"
                end)

            ["\n\n---\n\n## What #{exp.name} changes\n\n" <> Enum.join(bullets, "\n")]
          else
            _ -> []
          end
        end)

      Enum.join(sections)
    end
  end
```

- [ ] **Step 2: Compile + targeted tests**

Run: `mix compile --warnings-as-errors && mix test test/rule_maven_web 2>&1 | tee tmp/delta_cheat.log`
Expected: clean, PASS.

- [ ] **Step 3: Manual verify (dev server)**

With the Task 10 seeded delta and the expansion selected (persisted via the game page toggle), open `/games/<token>/cheatsheet` → "What <name> changes" section at the bottom with the rule + setup bullets. Deselect the expansion on the game page, reload the cheat sheet → section gone. `/cheatsheet/<version_id>` never shows deltas.

- [ ] **Step 4: Commit + clean up logs**

```bash
git add lib/rule_maven_web/controllers/cheat_sheet_controller.ex
git commit -m "feat: cheat sheet appends selected expansions' rule changes"
rm -f tmp/exp_cache.log tmp/exp_neighbors.log tmp/exp_sel.log tmp/exp_sel_live.log tmp/delta.log tmp/delta_live.log tmp/delta_cheat.log
```

---

## Deferred (explicitly out of scope)

- Delta verify/fact-check second pass (Setup has one; add if hallucinations observed).
- Prepare-page regen button for deltas (readiness step list is static; a conditional per-game step is a bigger change — re-running prepare or `ExpansionDelta.generate_async/1` from console covers admins for now).
- Invalidating/regenerating deltas when the expansion's rulebook is re-cleaned (delta is Settings-cached; re-run of enrichments overwrites).
- Suggestions / did-you-know / voices / theme expansion-awareness.
