# Unified Publish Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make solo and group `questions_log` rows go through the exact same publish gate — every row (not just group rows) is born `browsable: false` and can only become listable/vote-promotable after `PublishCheckWorker` clears it (or an admin force-publishes it), closing the current gap where solo rows auto-promote on vote quorum with zero content screen.

**Architecture:** Generalize the existing group-only gate (`questions_log.browsable` default, `AskWorker`'s enqueue branch, `PublishCheckWorker`'s guard/SQL) to apply regardless of `group_id`. Add one new admin capability (force-publish a stuck row) reusing the existing `Audit` log pattern already used by other admin actions in the same LiveView. No new schema columns; no new worker.

**Tech Stack:** Elixir / Phoenix / Ecto / Oban, Postgres migration, ExUnit + `Oban.Testing`.

## Global Constraints

- Full existing group-only test suite must stay green — this generalizes behavior, it does not change it for group rows.
- No compiler warnings; `mix test` for touched files must pass clean (repo's zero-warnings-zero-failures convention). Do not run the full suite unless asked — only the files this plan touches or adds.
- Existing rows are **not** backfilled/rewritten — the schema default change governs new inserts only.
- No new `questions_log` columns. Reuse `Jobs` (worker audit trail, already written by `PublishCheckWorker`) and `Audit` (admin-action trail, already used by `set_visibility`/`clear_flag` in `admin_live/questions.ex`) — do not invent a third logging mechanism.
- Admin force-publish is a manual override of an automated result, not a replacement for it — it must go through the same `Audit.log/3` pattern as `set_visibility`/`clear_flag` in `lib/rule_maven_web/live/admin_live/questions.ex:217-264`.

---

### Task 1: Migration — `browsable` column default

**Files:**
- Create: `priv/repo/migrations/<timestamp>_change_questions_log_browsable_default.exs`

**Interfaces:**
- Produces: DB-level default `false` for `questions_log.browsable` (schema-level change, no data rewrite).

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration change_questions_log_browsable_default`

- [ ] **Step 2: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.ChangeQuestionsLogBrowsableDefault do
  use Ecto.Migration

  def up do
    alter table(:questions_log) do
      modify :browsable, :boolean, default: false
    end
  end

  def down do
    alter table(:questions_log) do
      modify :browsable, :boolean, default: true
    end
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: migration applies with no errors; existing rows' stored `browsable` values are untouched (this only changes the column default applied to future inserts with no explicit value).

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/*_change_questions_log_browsable_default.exs
git commit -m "$(cat <<'EOF'
feat(db): default questions_log.browsable to false

Existing rows keep their stored value. Only new inserts are affected —
prerequisite for generalizing the publish gate to solo rows in the next
tasks.
EOF
)"
```

---

### Task 2: `QuestionLog` — generalize the insert-time gate, fix `crew_origin?/1`

**Files:**
- Modify: `lib/rule_maven/games/question_log.ex:32-51,151-158,238-262`
- Test: `test/rule_maven/games/question_log_test.exs`

**Interfaces:**
- Produces: `QuestionLog.crew_origin?/1` (unchanged public signature, corrected body); insert-time changeset behavior generalized (no new public function name needed — the private helper is renamed internally, callers only see `changeset/2`'s existing behavior).

**Context:** `crew_origin?/1`'s third clause, `crew_origin?(%{browsable: false}), do: true`, is only sound today because a non-group row is *always* born `browsable: true` — so `browsable == false` currently implies crew provenance. Once every row (solo included) is born `browsable: false` (Task 1 + this task), that implication breaks: a solo row waiting on `PublishCheckWorker` would be misidentified as crew-origin everywhere `crew_origin?/1` is read (`show.ex` hiding `raw_response`/protecting rows during regen, `games.ex:4678`'s vote-weight `unreviewable?` check). The clause is provably redundant for real crew rows today — every group-insert row already has `group_id` set (caught by clause 1), and `Groups.retract_contributions/1` (`lib/rule_maven/groups.ex:419-424`) always stamps `retracted_at` in the same `Repo.update_all` that clears `browsable` (caught by clause 2) — so removing clause 3 loses no real crew-detection coverage. It must be removed as part of this change, or every solo ask silently starts appearing as a "crew row" the moment it's created.

- [ ] **Step 1: Write the failing test proving the current bug would exist if left unfixed**

Add to `test/rule_maven/games/question_log_test.exs` (create the `describe` block if the file doesn't already have one):

```elixir
  describe "crew_origin?/1" do
    test "a solo (non-group) row awaiting the publish screen is not crew-origin" do
      pending_solo = %RuleMaven.Games.QuestionLog{
        group_id: nil,
        retracted_at: nil,
        browsable: false
      }

      refute RuleMaven.Games.QuestionLog.crew_origin?(pending_solo)
    end

    test "a group row is still crew-origin while unbrowsable" do
      group_row = %RuleMaven.Games.QuestionLog{group_id: 1, retracted_at: nil, browsable: false}
      assert RuleMaven.Games.QuestionLog.crew_origin?(group_row)
    end

    test "a deleted group's orphaned row is still crew-origin via retracted_at" do
      orphaned = %RuleMaven.Games.QuestionLog{
        group_id: nil,
        retracted_at: DateTime.utc_now(),
        browsable: false
      }

      assert RuleMaven.Games.QuestionLog.crew_origin?(orphaned)
    end
  end
```

- [ ] **Step 2: Run it, confirm the first test fails against current code**

Run: `mix test test/rule_maven/games/question_log_test.exs -v`
Expected: `a solo (non-group) row awaiting the publish screen is not crew-origin` FAILS (current code's third clause returns `true`); the other two PASS already.

- [ ] **Step 3: Fix `crew_origin?/1`**

In `lib/rule_maven/games/question_log.ex`, replace:

```elixir
  def crew_origin?(%{group_id: gid}) when not is_nil(gid), do: true
  def crew_origin?(%{retracted_at: at}) when not is_nil(at), do: true
  def crew_origin?(%{browsable: false}), do: true
  def crew_origin?(_q), do: false
```

with:

```elixir
  def crew_origin?(%{group_id: gid}) when not is_nil(gid), do: true
  def crew_origin?(%{retracted_at: at}) when not is_nil(at), do: true
  def crew_origin?(_q), do: false
```

Update the moduledoc above it (currently lines 138-154) to drop the `browsable == false` bullet — it described a signal that no longer holds once solo rows can also be `browsable: false`. Replace the three-bullet list with:

```elixir
  @doc """
  Did this row come out of a crew? The question is NOT "is `group_id` set" —
  that column is `on_delete: :nilify_all`, so a deleted crew's rows keep their
  unscreened text and lose the only marker saying where it came from.

  Two signals, either of which is proof of crew provenance, and the second
  survives the nilify:

    * `group_id` — the crew still exists.
    * `retracted_at` — only `Groups.retract_contributions/1` writes it, and it
      writes it to crew rows only. Set before the group is deleted, so it
      outlives the FK.

  `browsable == false` is NOT a signal here: every row, solo or group, is now
  born unbrowsable pending the publish screen (see `PublishCheckWorker`), so
  it no longer distinguishes crew provenance from "hasn't been screened yet."
  """
```

- [ ] **Step 4: Also fix the `browsable` field doc and `default_group_unbrowsable/1`**

Update the field comment at lines 32-36 (currently says "Group rows are written false... only by PublishCheckWorker") to describe both populations:

```elixir
    # May this row's QUESTION TEXT be listed to a non-asker? Distinct from
    # `pooled` (may its ANSWER serve the cross-user cache — which never exposes
    # the asker's wording or identity). Every row — solo or group — is written
    # false and is flipped true only by PublishCheckWorker (or an admin
    # force-publish override), which fails closed.
    field :browsable, :boolean, default: false
```

(The schema `default: false` here mirrors the DB default from Task 1 — Ecto's schema default and the DB default should agree.)

Rename `default_group_unbrowsable/1` to `default_unbrowsable/1` and drop its `group_id` condition:

```elixir
    |> default_unbrowsable()
  end

  # Every row is born unbrowsable unless the caller says otherwise, so the
  # gate fails closed even if a future insert path forgets to pass `browsable`.
  # Was group-only; generalized so a solo row gets the identical treatment —
  # see PublishCheckWorker and AskWorker for the rest of the gate.
  #
  # INSERT only: on update, `browsable` is absent from most changesets (vote
  # counts, trust, staleness), and forcing it false there would silently undo
  # a publish check that had already passed.
  #
  # Keyed on the cast params, NOT on `get_change/2`: the field's schema default
  # is `false`, so a caller explicitly passing `browsable: true` produces no
  # *change* at all if the struct already defaults there, and a
  # `get_change == nil` test would read that as "caller said nothing" and slam
  # it shut regardless.
  defp default_unbrowsable(%Ecto.Changeset{data: %__MODULE__{id: nil}} = changeset) do
    explicit? =
      Map.has_key?(changeset.params || %{}, "browsable") or
        Map.has_key?(changeset.params || %{}, :browsable)

    if not explicit? do
      put_change(changeset, :browsable, false)
    else
      changeset
    end
  end

  defp default_unbrowsable(changeset), do: changeset
```

Also fix `listed_answer/1`'s moduledoc (lines 170-179) and `listed_question/1`'s (lines 96-119) — both currently say "A non-crew row is born `browsable: true`". Change to: "A non-crew row starts unbrowsable exactly like a crew row and is cleared by the same `PublishCheckWorker` gate; it was never treated differently once this generalized."

- [ ] **Step 5: Run the tests again, confirm all pass**

Run: `mix test test/rule_maven/games/question_log_test.exs -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/games/question_log.ex test/rule_maven/games/question_log_test.exs
git commit -m "$(cat <<'EOF'
fix(games): generalize QuestionLog's unbrowsable gate to all rows

default_group_unbrowsable/1 -> default_unbrowsable/1, no longer gated on
group_id. crew_origin?/1's browsable-based clause is dropped: it was
already redundant for real crew rows (group_id or retracted_at always
catch them) and becomes actively wrong once solo rows also default to
browsable: false.
EOF
)"
```

---

### Task 3: `AskWorker` — unify the enqueue branch

**Files:**
- Modify: `lib/rule_maven/workers/ask_worker.ex` (the branch around what is currently lines ~510-549, and the `unscrubbed_crew_row?/3` helper)
- Test: `test/rule_maven/workers/ask_worker_publish_gate_test.exs`

**Interfaces:**
- Consumes: `PublishCheckWorker.enqueue/1` (existing, unchanged signature — `enqueue(question_log_id)`).
- Produces: `AskWorker` no longer calls `Games.mark_pooled/1` for solo rows; every citation-valid, non-`skip_normalize` row (solo or group) goes through `PublishCheckWorker.enqueue/1` instead.

**Context:** Today the branch is:

```elixir
if group_id do
  if updated.citation_valid and not skip_normalize do
    RuleMaven.Workers.PublishCheckWorker.enqueue(question_log_id)
  end
else
  Games.mark_pooled(updated)
end
```

This task removes the `group_id` split entirely.

- [ ] **Step 1: Write the failing test**

In `test/rule_maven/workers/ask_worker_publish_gate_test.exs`, the existing test `"a non-group ask stays browsable and enqueues no publish check"` (lines 137-163) encodes the OLD behavior and must be replaced — that's exactly the asymmetry this plan removes. Replace it with:

```elixir
  test "a solo ask is written unbrowsable and enqueues the publish check, same as a group ask" do
    game = seeded_game(9202)
    u = user("pgw_solo")
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private"
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => u.id,
               "skip_pool" => true
             })

    assert Repo.reload!(ql).browsable == false
    assert_enqueued(worker: PublishCheckWorker, args: %{"question_log_id" => ql.id})
  end

  test "a skip_normalize solo ask never enqueues the publish check" do
    game = seeded_game(9213)
    u = user("pgw_solo_verbatim")
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How do I start, Dave?",
        answer: "Thinking...",
        visibility: "private"
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => u.id,
               "skip_pool" => true,
               "skip_normalize" => true
             })

    assert Repo.reload!(ql).browsable == false
    refute_enqueued(worker: PublishCheckWorker)
  end

  test "an ungrounded solo ask is not pooled and runs no publish check" do
    game = seeded_game(9214)
    u = user("pgw_solo_ungrounded")

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "You roll the die to start.",
         citations: [
           %{"quote" => "Dragons always fly at dawn.", "page" => 1, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :embed_mock)
      Application.delete_env(:rule_maven, :llm_mock)
    end)

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private"
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => u.id,
               "skip_pool" => true
             })

    updated = Repo.reload!(ql)
    assert updated.citation_valid == false
    assert updated.pooled == false
    assert updated.browsable == false
    refute_enqueued(worker: PublishCheckWorker)
  end
```

- [ ] **Step 2: Run to confirm the new tests fail**

Run: `mix test test/rule_maven/workers/ask_worker_publish_gate_test.exs -v`
Expected: the replaced test and the two new ones FAIL (current code still calls `Games.mark_pooled/1` inline for solo, leaving `browsable: true` and nothing enqueued).

- [ ] **Step 3: Generalize the `AskWorker` branch**

Find the branch (currently reads `if group_id do ... else Games.mark_pooled(updated) end`) and replace with:

```elixir
                        if updated.citation_valid and not skip_normalize do
                          RuleMaven.Workers.PublishCheckWorker.enqueue(question_log_id)
                        end
```

Update the comment block immediately above it (the long comment currently explaining "A CREW row does not enter the pool here...") to drop the crew-specific framing — replace references to "a CREW row"/"the crew" with "a row" throughout that comment block, since the same reasoning (pool-first-revoke-later was wrong; screening now gates both `pooled` and `browsable` together) now applies uniformly.

Also generalize the guard helper. Find `unscrubbed_crew_row?/3` (used in the `unless pool_hit? or never_pool or consent_withdrawn?(...) or unscrubbed_crew_row?(group_id, skip_normalize, updated)` guard) and rename it to `unscrubbed_row?/2`, dropping its `group_id` parameter if its body branches on it — check its definition; if it only used `group_id` to decide "is this even a crew row," drop that branch and keep only the "not yet scrubbed" logic, since that now applies regardless of population.

- [ ] **Step 4: Run tests again, confirm they pass**

Run: `mix test test/rule_maven/workers/ask_worker_publish_gate_test.exs -v`
Expected: all PASS, including every pre-existing group-row test in the file (they must still pass unchanged — this is a generalization, not a behavior change for group rows).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/workers/ask_worker.ex test/rule_maven/workers/ask_worker_publish_gate_test.exs
git commit -m "$(cat <<'EOF'
feat(ask): route solo asks through PublishCheckWorker, same as group asks

Drops AskWorker's group_id branch. A solo citation-valid ask no longer
pools inline via mark_pooled/1 — it enqueues the same publish screen a
group ask does, and only becomes pooled/browsable once that clears (or
an admin force-publishes it).
EOF
)"
```

---

### Task 4: `PublishCheckWorker` — accept rows with no `group_id`

**Files:**
- Modify: `lib/rule_maven/workers/publish_check_worker.ex` (moduledoc, `screen/2` head, the "no"-outcome `Repo.update_all` in `maybe_publish/3`, the "yes"-outcome `Repo.update_all`)
- Test: `test/rule_maven/workers/publish_check_worker_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PublishCheckWorker.perform/1` now screens both solo and group rows; behavior for group rows is byte-for-byte unchanged.

**Context:** Three spots assume `group_id` is present:
1. `screen/2`'s function head guards `when not is_nil(gid)`.
2. The "no" (clears the gate) `Repo.update_all` inner-joins `groups` and requires `g.contribute_to_community == true` — for `group_id: nil` this join matches zero rows, permanently blocking every solo row.
3. The "yes" (un-pools) `Repo.update_all` requires `where: not is_nil(q.group_id)`.

- [ ] **Step 1: Write the failing tests**

In `test/rule_maven/workers/publish_check_worker_test.exs`, the existing test `"a non-group row is never touched"` (around line 204) encodes the OLD behavior and must be replaced. Replace it with:

```elixir
    test "a solo row is screened the same as a group row" do
      stub_llm("no")

      ql =
        question_fixture(
          group_id: nil,
          cleaned_question: "May a player retract a move?",
          browsable: false,
          pooled: false,
          citation_valid: true,
          question_normalized: true
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      row = Repo.reload!(ql)
      assert row.browsable == true
      assert row.pooled == true
    end

    test "a flagged solo row stays unbrowsable and unpools if it was pooled" do
      stub_llm("yes")

      ql =
        question_fixture(
          group_id: nil,
          cleaned_question: "Can Dave retract his move?",
          answer: "Dave can retract his move.",
          browsable: false,
          pooled: true,
          citation_valid: true,
          question_normalized: true
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})

      row = Repo.reload!(ql)
      refute row.browsable
      refute row.pooled
    end
```

- [ ] **Step 2: Run to confirm failures**

Run: `mix test test/rule_maven/workers/publish_check_worker_test.exs -v`
Expected: both new tests FAIL — `screen/2`'s `when not is_nil(gid)` guard means the worker no-ops on a `group_id: nil` row today, leaving `browsable: false` in both cases (so the first test's `assert row.browsable == true` fails; the second test's assertions happen to already hold vacuously but for the wrong reason — the worker never ran).

- [ ] **Step 3: Relax the `screen/2` guard**

In `lib/rule_maven/workers/publish_check_worker.ex`, change:

```elixir
  defp screen(
         %QuestionLog{
           group_id: gid,
           browsable: false,
           citation_valid: true,
           cleaned_question: cleaned
         } = ql,
         oban_id
       )
       when not is_nil(gid) and is_binary(cleaned) do
```

to:

```elixir
  defp screen(
         %QuestionLog{
           browsable: false,
           citation_valid: true,
           cleaned_question: cleaned
         } = ql,
         oban_id
       )
       when is_binary(cleaned) do
```

(Drop the now-unused `group_id: gid` binding and its guard clause.)

- [ ] **Step 4: Make the "no"-outcome SQL conditional on `group_id`**

In `maybe_publish/3`, the "no" branch currently reads:

```elixir
      {published, _} =
        Repo.update_all(
          from(q in QuestionLog,
            join: g in RuleMaven.Groups.Group,
            on: g.id == q.group_id,
            where: q.id == ^ql.id,
            where: q.browsable == false,
            where: q.citation_valid == true,
            where: is_nil(q.retracted_at),
            where: q.question_normalized == true,
            where: q.cleaned_question == ^screened,
            where: g.contribute_to_community == true
          ),
          set: [browsable: true, pooled: true]
        )
```

Replace with a base query that only joins `groups` when the row actually has one:

```elixir
      base_query =
        from(q in QuestionLog,
          where: q.id == ^ql.id,
          where: q.browsable == false,
          where: q.citation_valid == true,
          where: is_nil(q.retracted_at),
          where: q.question_normalized == true,
          where: q.cleaned_question == ^screened
        )

      publish_query =
        if ql.group_id do
          from(q in base_query,
            join: g in RuleMaven.Groups.Group,
            on: g.id == q.group_id,
            where: g.contribute_to_community == true
          )
        else
          base_query
        end

      {published, _} = Repo.update_all(publish_query, set: [browsable: true, pooled: true])
```

Add a one-line comment above `publish_query`: solo rows have no group-level consent flag to check — their only consent lever is `never_pool`, already enforced upstream in `AskWorker` before this worker is ever enqueued.

- [ ] **Step 5: Relax the "yes"-outcome SQL**

Find:

```elixir
        {unpooled, _} =
          Repo.update_all(
            from(q in QuestionLog,
              where: q.id == ^ql.id,
              where: q.pooled == true,
              where: not is_nil(q.group_id)
            ),
            set: [pooled: false]
          )
```

Replace with:

```elixir
        {unpooled, _} =
          Repo.update_all(
            from(q in QuestionLog,
              where: q.id == ^ql.id,
              where: q.pooled == true
            ),
            set: [pooled: false]
          )
```

- [ ] **Step 6: Update the moduledoc**

Change the opening line from "Screens a GROUP question's scrubbed, normalized text..." to "Screens any row's scrubbed, normalized text (`cleaned_question`) before it may be listed on a public browse surface — solo or group, no distinction." Adjust the rest of the moduledoc's crew-specific wording (it currently says "A crew row reaches it `browsable: false`...") to "A row reaches it `browsable: false`..." — the underlying reasoning (fail-closed, pool-and-browsable move together) is unchanged and population-agnostic.

- [ ] **Step 7: Run all publish-check tests, confirm everything passes**

Run: `mix test test/rule_maven/workers/publish_check_worker_test.exs -v`
Expected: all PASS — the two new solo tests, and every pre-existing group test (the "row whose crew has stopped contributing" test at line ~268 must still pass unchanged, proving the group consent join still applies when `group_id` is set).

- [ ] **Step 8: Commit**

```bash
git add lib/rule_maven/workers/publish_check_worker.ex test/rule_maven/workers/publish_check_worker_test.exs
git commit -m "$(cat <<'EOF'
feat(publish_check): screen solo rows, not just group rows

screen/2 no longer requires group_id. The "no" (publish) outcome only
joins groups/checks contribute_to_community when the row actually has a
group_id; a solo row has no group-level consent flag (never_pool is its
only lever, already enforced upstream). The "yes" (un-pool) outcome now
un-pools any row, not just group rows.
EOF
)"
```

---

### Task 5: Admin surface — surface stuck rows, add a force-publish override

**Files:**
- Modify: `lib/rule_maven/games.ex` (add `publish_pending_count/0`, add a `"publish_pending"` status branch to `admin_list_questions/1`, add `force_publish_question/1`)
- Modify: `lib/rule_maven_web/live/admin_live/questions.ex` (new `handle_event("force_publish", ...)`, new filter option in the status `<select>`, a "Force publish" button on a stuck row)
- Modify: `lib/rule_maven_web/live/admin_live/index.ex` (badge, mirroring the existing `review_backlog`)
- Test: `test/rule_maven/games_test.exs` (or wherever `admin_list_questions/1`/count functions are already tested — check with `grep -n "needs_review_count" test/rule_maven/games_test.exs` and add beside it), `test/rule_maven_web/live/admin_live/questions_test.exs`

**Interfaces:**
- Produces: `Games.publish_pending_count/0 :: integer`, `Games.force_publish_question/1 :: QuestionLog.t() -> {:ok, QuestionLog.t()}`.
- Consumes: `RuleMaven.Audit.log/3` (existing, used identically to `set_visibility`/`clear_flag` in the same file).

- [ ] **Step 1: Write the failing test for `Games.publish_pending_count/0` and `Games.force_publish_question/1`**

Find the existing test for `needs_review_count/0` (run `grep -n "needs_review_count" test/rule_maven/games_test.exs` to locate it) and add nearby:

```elixir
  describe "publish_pending_count/0" do
    test "counts citation-valid rows stuck behind the publish gate" do
      game = game_fixture()
      user = user_fixture()

      {:ok, stuck} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Stuck row",
          answer: "answer",
          browsable: false,
          citation_valid: true
        })

      {:ok, _cleared} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Cleared row",
          answer: "answer",
          browsable: true,
          citation_valid: true
        })

      assert Games.publish_pending_count() >= 1
      assert stuck.id in (Games.admin_list_questions(status: "publish_pending") |> Enum.map(& &1.id))
    end
  end

  describe "force_publish_question/1" do
    test "sets browsable and pooled regardless of the automated screen" do
      game = game_fixture()
      user = user_fixture()

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Stuck row",
          answer: "answer",
          browsable: false,
          citation_valid: true
        })

      assert {:ok, updated} = Games.force_publish_question(ql)
      assert updated.browsable == true
      assert updated.pooled == true
    end

    test "does not pool a row whose citation was never grounded" do
      game = game_fixture()
      user = user_fixture()

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Ungrounded row",
          answer: "answer",
          browsable: false,
          citation_valid: false
        })

      assert {:ok, updated} = Games.force_publish_question(ql)
      assert updated.browsable == true
      assert updated.pooled == false
    end
  end
```

(Adjust `game_fixture()`/`user_fixture()` calls to match whatever helpers `test/rule_maven/games_test.exs` already imports — check its top-of-file `import`/`alias` list before adding these.)

- [ ] **Step 2: Run to confirm failures**

Run: `mix test test/rule_maven/games_test.exs -v`
Expected: FAIL — `Games.publish_pending_count/0` and `Games.force_publish_question/1` are undefined, and `admin_list_questions/1` doesn't recognize `"publish_pending"`.

- [ ] **Step 3: Implement `publish_pending_count/0`**

Add next to `needs_review_count/0` in `lib/rule_maven/games.ex`:

```elixir
  @doc """
  Count of rows stuck behind the publish gate — citation-valid, not yet
  browsable, not a skip_normalize row (which never publishes and so is not
  "stuck", just permanently excluded). Solo and group rows both land here;
  see PublishCheckWorker.
  """
  def publish_pending_count do
    Repo.aggregate(
      from(q in QuestionLog,
        where:
          q.browsable == false and q.citation_valid == true and
            not is_nil(q.cleaned_question)
      ),
      :count
    )
  end
```

- [ ] **Step 4: Add the `"publish_pending"` branch to `admin_list_questions/1`**

In the `case status do` block (`lib/rule_maven/games.ex:2576-2596`), add:

```elixir
        "publish_pending" ->
          from(q in query,
            where:
              q.browsable == false and q.citation_valid == true and
                not is_nil(q.cleaned_question)
          )
```

alongside the existing `"needs_review"` branch (same `where` predicate as `publish_pending_count/0` — keep them in sync).

- [ ] **Step 5: Implement `force_publish_question/1`**

Add near `update_question_visibility/2`:

```elixir
  @doc """
  Admin override: mark a row browsable regardless of what PublishCheckWorker's
  automated screen decided (or whether it has run at all yet). Does not touch
  `visibility` — promoting to community stays the separate, existing
  `update_question_visibility/2` action; this only unlocks the row from the
  publish gate.
  """
  def force_publish_question(%QuestionLog{} = q) do
    attrs = %{browsable: true, pooled: q.citation_valid}

    with {:ok, updated} <- q |> QuestionLog.changeset(attrs) |> Repo.update() do
      RuleMaven.Games.Trust.recompute_trust(updated)
      if updated.user_id, do: RuleMaven.Games.Trust.recompute_reputation(updated.user_id)
      {:ok, updated}
    end
  end
```

- [ ] **Step 6: Run tests, confirm they pass**

Run: `mix test test/rule_maven/games_test.exs -v`
Expected: all PASS.

- [ ] **Step 7: Wire the admin filter option and force-publish button into `admin_live/questions.ex`**

Add `"publish_pending"` to the accepted status list in `handle_params/3` (`lib/rule_maven_web/live/admin_live/questions.ex:47`):

```elixir
        s when s in ["needs_review", "answered", "pending", "refused", "error", "publish_pending"] ->
```

Add the new event handler next to `clear_flag` (after line 264):

```elixir
  def handle_event("force_publish", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.questions, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      q ->
        case Games.force_publish_question(q) do
          {:ok, _} ->
            Audit.log(socket.assigns.current_user, "question.force_publish",
              target_type: "question",
              target_id: q.id,
              target_label: admin_question_text(q)
            )

            {:noreply, reload(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't force-publish that row.")}
        end
    end
  end
```

Add `<option value="publish_pending">Stuck (publish gate)</option>` to the status `<select>` template (same block as the existing `needs_review`/`answered`/etc. options, around line 502) and a "Force publish" button next to the existing "Re-approve" (`clear_flag`) button, rendered only when `q.browsable == false and q.citation_valid == true`:

```heex
<button
  :if={not q.browsable and q.citation_valid}
  phx-click="force_publish"
  phx-value-id={q.id}
  class="btn-secondary"
>
  Force publish
</button>
```

(Match the existing button markup style used for the "Re-approve" button beside it — copy its class/wrapper structure rather than introducing a new one.)

- [ ] **Step 8: Add the admin dashboard badge**

In `lib/rule_maven_web/live/admin_live/index.ex`, add next to `review_backlog: Games.needs_review_count(),`:

```elixir
         publish_backlog: Games.publish_pending_count(),
```

And add a badge card mirroring the existing `review_backlog` one (find the block around line 304-311 using `@review_backlog` and duplicate its structure for `@publish_backlog`, linking to `~p"/admin/questions?status=publish_pending"`).

- [ ] **Step 9: Manual/feature-test verification**

Add a LiveView test to `test/rule_maven_web/live/admin_live/questions_test.exs` (check the file's existing setup helpers first — mirror whatever pattern the `set_visibility`/`clear_flag` tests already use in that file):

```elixir
  test "admin can force-publish a stuck row", %{conn: conn} do
    game = game_fixture()
    admin = admin_user_fixture()
    user = user_fixture()

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Stuck row",
        answer: "answer",
        browsable: false,
        citation_valid: true
      })

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/admin/questions")

    view
    |> element("button[phx-click='force_publish'][phx-value-id='#{ql.id}']")
    |> render_click()

    assert Repo.reload!(ql).browsable == true
  end
```

(Adjust `admin_user_fixture/0`/`log_in/2`/`user_fixture/0`/`game_fixture/0` to whatever helpers the rest of `questions_test.exs` already uses — check the top of that file before writing this, since this repo has no generic `AccountsFixtures` per prior test-writing experience in this codebase.)

Run: `mix test test/rule_maven_web/live/admin_live/questions_test.exs -v`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/rule_maven/games.ex lib/rule_maven_web/live/admin_live/questions.ex lib/rule_maven_web/live/admin_live/index.ex test/rule_maven/games_test.exs test/rule_maven_web/live/admin_live/questions_test.exs
git commit -m "$(cat <<'EOF'
feat(admin): surface publish-gate-stuck rows, add force-publish override

New Games.publish_pending_count/0 + "publish_pending" admin_list_questions
filter surface rows (solo or group) waiting on PublishCheckWorker or stuck
on an ambiguous/flagged result. New Games.force_publish_question/1 lets an
admin manually clear the gate, audited via the same Audit.log pattern as
the existing set_visibility/clear_flag actions.
EOF
)"
```

---

### Task 6: Full touched-file verification pass

**Files:** none new — this is a verification-only task.

- [ ] **Step 1: Run every test file this plan touched or added, together**

Run:
```bash
mix test test/rule_maven/games/question_log_test.exs \
         test/rule_maven/workers/ask_worker_publish_gate_test.exs \
         test/rule_maven/workers/publish_check_worker_test.exs \
         test/rule_maven/games_test.exs \
         test/rule_maven_web/live/admin_live/questions_test.exs \
         -v
```
Expected: all PASS, zero compiler warnings in the output.

- [ ] **Step 2: Run the pre-existing group-focused suites once more in isolation to confirm zero regression**

Run: `mix test test/rule_maven/llm_group_gate_test.exs test/rule_maven/group_gate_holes_test.exs -v`
Expected: all PASS unchanged — this plan generalizes the gate, it must not alter group-row behavior.

- [ ] **Step 3: Confirm no compiler warnings across the touched files**

Run: `mix compile --warnings-as-errors`
Expected: clean compile, zero warnings.

(No commit for this task — it's verification. If anything fails, fix it under the task that owns the broken file and re-run this task.)

## Self-review notes

- Spec coverage: Task 1 = spec §5 (migration); Task 2 = spec §1 (data model) + the `crew_origin?/1` landmine found during file-mapping (not in the original spec, but directly caused by implementing §1 — fixing it is required for the spec's own goal, not scope creep); Task 3 = spec §2; Task 4 = spec §3; Task 5 = spec §4 (admin surface), using `Audit.log/3` instead of a new `Jobs` "admin_override" run type — `Audit` is this file's *existing* convention for admin-initiated actions (`set_visibility`, `clear_flag` both already use it), so this is a "follow established patterns" correction, not a deviation from the spec's intent; Task 6 = spec's testing section, run holistically once per-task tests are green.
- No placeholders: every step has literal file paths, literal code, and literal `mix test` commands with stated expected output.
- Type/name consistency check: `Games.publish_pending_count/0`, `Games.force_publish_question/1`, `QuestionLog.crew_origin?/1`, `PublishCheckWorker.enqueue/1` are used with the same names/arities everywhere they appear across tasks.
