# Group Publish Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a group's answers feed the community cache (as they already do) while its *question text* becomes publicly listable only in scrubbed canonical form, behind four gates.

**Architecture:** Split the two meanings currently carried by `pooled` — "servable by cache" stays on `pooled`, "listable in browse" moves to a new orthogonal `browsable` column. Group rows are written unbrowsable and are flipped browsable only by an off-critical-path Oban worker that fails closed.

**Tech Stack:** Phoenix LiveView, Ecto/PostgreSQL, Oban, existing `RuleMaven.Prompts` registry, existing `RuleMaven.LLM`.

**Spec:** `docs/superpowers/specs/2026-07-11-group-publish-gates-design.md` — read it if a requirement here is ambiguous.

## Global Constraints

- **Zero warnings, zero test failures.** A compiler warning or a red test is never
  excused as "pre-existing". `mix compile --warnings-as-errors` must stay clean.
- **Run only the tests relevant to the change.** Not the full suite unless asked.
  Run `mix test` in the FOREGROUND — never background it.
- **Every LLM prompt lives in the `RuleMaven.Prompts` registry.** Never hardcode a
  prompt string in a module.
- **Every new Oban worker reports to the unified Jobs log** (follow the pattern in
  an existing worker, e.g. `TagQuestionWorker`).
- **Fail closed.** Any gate that cannot reach a definite "safe" verdict leaves the
  row unbrowsable. An LLM error, a timeout, a malformed reply, or a missing
  canonical question all mean `browsable` stays `false`.
- **Mobile-first.** Any UI change is verified at 390px width.
- **Test helper conventions (this repo has NO `AccountsFixtures`, no
  `user_fixture/0`, no `log_in_user/2`):**
  - Users: `RuleMaven.Users.create_user/1` with a unique username + email. Pass
    `role: "admin"` for an admin (`update_role/2` does not exist).
  - Login in conn tests: `defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})`
  - `RuleMaven.GamesFixtures.game_fixture/1` defaults `bgg_id: 42` — pass a distinct
    one for a second game.
  - `RuleMaven.GroupsFixtures.group_fixture/2` exists.
  - Quota: `recent_question_count/2` counts `LLM.Log` "ask" rows. A test that asks
    repeatedly must log one, or the quota assertions drift.
- **Sabotage-check every gate.** After a gate's test passes, remove the guard,
  confirm the test goes red, restore it. A gate whose test still passes with the
  guard removed is not a gate.

---

### Task 1: Migration + schema fields

**Files:**
- Create: `priv/repo/migrations/20260711100000_add_publish_gates.exs`
- Modify: `lib/rule_maven/games/question_log.ex`
- Modify: `lib/rule_maven/groups/group.ex`
- Test: `test/rule_maven/games/question_log_test.exs` (create if absent)

**Interfaces:**
- Produces: `QuestionLog.browsable :: boolean` (default `true`), castable in
  `changeset/2`. `Group.contribute_to_community :: boolean` (default `true`),
  castable in `changeset/2`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddPublishGates do
  use Ecto.Migration

  def change do
    # May this row's QUESTION TEXT be shown to someone who is not the asker?
    # Orthogonal to `pooled` (servable by cache) and `visibility`. Default true
    # preserves every existing non-group row's behaviour exactly.
    alter table(:questions_log) do
      add :browsable, :boolean, null: false, default: true
    end

    alter table(:groups) do
      add :contribute_to_community, :boolean, null: false, default: true
    end

    # The browse surfaces (unverified_pool_questions/2, DirectPromotionWorker)
    # filter on browsable alongside pooled.
    create index(:questions_log, [:game_id, :browsable])
  end
end
```

- [ ] **Step 2: Add the fields to the schemas**

In `lib/rule_maven/games/question_log.ex`, beside `field :pooled`:

```elixir
    # May this row's QUESTION TEXT be listed to a non-asker? Distinct from
    # `pooled` (may its ANSWER serve the cross-user cache — which never exposes
    # the asker's wording or identity). Group rows are written false and are
    # flipped true only by PublishCheckWorker, which fails closed.
    field :browsable, :boolean, default: true
```

Add `:browsable` to the `cast/3` list in `changeset/2`.

In `lib/rule_maven/groups/group.ex`, add:

```elixir
    field :contribute_to_community, :boolean, default: true
```

Add `:contribute_to_community` to the `cast/3` list in `changeset/2`.

- [ ] **Step 3: Write the failing test**

```elixir
test "browsable defaults to true and is castable" do
  changeset = QuestionLog.changeset(%QuestionLog{}, %{browsable: false})
  assert Ecto.Changeset.get_field(changeset, :browsable) == false
  assert %QuestionLog{}.browsable == true
end
```

- [ ] **Step 4: Run migration + tests**

Run: `mix ecto.migrate && mix test test/rule_maven/games/question_log_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations lib/rule_maven/games/question_log.ex lib/rule_maven/groups/group.ex test/
git commit -m "feat(groups): add browsable + contribute_to_community columns"
```

---

### Task 2: Prompts — normalize scrub + publish check

**Files:**
- Modify: `lib/rule_maven/prompts.ex`
- Test: `test/rule_maven/prompts_test.exs`

**Interfaces:**
- Produces: registry keys `publish_check_system` and `publish_check` (vars:
  `question`). The amended `normalize_question` prompt.

- [ ] **Step 1: Amend the normalize prompt (Gate 1)**

`@normalize_question` currently reads:

```
Rewrite this player's question as a standalone canonical question (resolve pronouns, add missing context, under 12 words, no game name):
```

Change that instruction line to:

```
Rewrite this player's question as a standalone canonical question (resolve pronouns, add missing context, under 12 words, no game name).
Remove anything personal: player names, proper nouns that are not game terms, and any narrative about who did what. Keep only the rules question itself.
```

Leave the surrounding template (vars, `{{context_block}}`, `{{question}}`) unchanged.

- [ ] **Step 2: Add the publish-check prompts (Gate 2)**

Modelled on `@pool_tiebreaker_system` / `@pool_tiebreaker` — one-word output.

```elixir
  # ──────────────────────────────────────────────────────────────────────────
  # Publish check. Run by PublishCheckWorker on a GROUP row's canonical question
  # before that text may be listed on a public browse surface. Fails closed:
  # anything other than a clean "no" leaves the row unbrowsable.
  # Vars: question (the canonical question text).
  # ──────────────────────────────────────────────────────────────────────────
  @publish_check_system """
  You screen board-game rules questions before they are published publicly. Answer with exactly one word: "yes" or "no" — nothing else, no punctuation, no explanation.

  Answer "yes" if the question contains ANY of: a person's name, a nickname, initials, a place a person could be identified by, or narrative about specific people ("my brother", "Dave's turn"). Generic role words that every game uses — "a player", "the active player", "an opponent" — are NOT personal, answer "no" for those.

  When uncertain, answer "yes". A false "yes" costs nothing; a false "no" publishes someone's personal information permanently.

  Always the lowercase English word "yes" or "no", regardless of the question's language.
  """

  @publish_check """
  Question: {{question}}

  Does it contain a person's name or personal information? Answer yes or no.
  """
```

Register both, `group: "Q&A"`:

```elixir
    %{
      key: "publish_check_system",
      group: "Q&A",
      label: "Publish check — system",
      description:
        "System primer for the yes/no personal-information screen run on a group question's canonical text before it may be listed publicly.",
      vars: [],
      default: @publish_check_system
    },
    %{
      key: "publish_check",
      group: "Q&A",
      label: "Publish check — prompt",
      description:
        "Screens a group question's canonical text for names/personal information before it becomes browsable. Fails closed.",
      vars: ~w(question),
      default: @publish_check
    },
```

- [ ] **Step 3: Write the failing test**

```elixir
test "publish_check prompts are registered and render" do
  assert RuleMaven.Prompts.template("publish_check_system") =~ "yes"
  rendered = RuleMaven.Prompts.render("publish_check", %{question: "May a player retract a move?"})
  assert rendered =~ "May a player retract a move?"
end

test "normalize prompt instructs removal of personal content" do
  assert RuleMaven.Prompts.template("normalize_question") =~ "player names"
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/prompts_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(prompts): normalize scrubs personal content; add publish-check screen"
```

---

### Task 3: PublishCheckWorker

**Files:**
- Create: `lib/rule_maven/workers/publish_check_worker.ex`
- Test: `test/rule_maven/workers/publish_check_worker_test.exs`

**Interfaces:**
- Consumes: `Prompts.render("publish_check", %{question: cleaned})`,
  `QuestionLog.browsable` (Task 1).
- Produces: `PublishCheckWorker.enqueue(question_log_id)` — called by `AskWorker`
  in Task 4.

**Read first:** `lib/rule_maven/workers/tag_question_worker.ex` — copy its
`enqueue/1` shape, its Jobs-log reporting, and its `use Oban.Worker` options.

- [ ] **Step 1: Write the failing tests**

```elixir
describe "perform/1" do
  test "a clean cleaned question becomes browsable" do
    # stub the LLM to return "no"
    ql = group_question_fixture(cleaned_question: "May a player retract a move?", browsable: false)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == true
  end

  test "a flagged question stays unbrowsable" do
    # stub the LLM to return "yes"
    ql = group_question_fixture(cleaned_question: "Can Dave retract his move?", browsable: false)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == false
  end

  test "a missing cleaned question stays unbrowsable and makes no LLM call" do
    ql = group_question_fixture(cleaned_question: nil, browsable: false)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == false
  end

  test "an LLM error fails closed" do
    # stub the LLM to return {:error, :timeout}
    ql = group_question_fixture(cleaned_question: "May a player retract a move?", browsable: false)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == false
  end

  test "a garbage LLM reply fails closed" do
    # stub the LLM to return "Sure! I think no."
    ql = group_question_fixture(cleaned_question: "May a player retract a move?", browsable: false)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == false
  end

  test "a non-group row is never touched" do
    ql = question_fixture(group_id: nil, browsable: true)
    assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
    assert Repo.reload!(ql).browsable == true
  end
end
```

Use whatever LLM stubbing mechanism the existing worker tests already use — check
`test/rule_maven/workers/` for the established pattern and follow it. Do not invent
a new one.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/workers/publish_check_worker_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement the worker**

```elixir
defmodule RuleMaven.Workers.PublishCheckWorker do
  @moduledoc """
  Screens a GROUP question's cleaned text before it may be listed on a public
  browse surface (the Unverified tab, community promotion).

  A group row is written `browsable: false` by AskWorker. This worker is the ONLY
  thing that flips it true, and it does so only on an unambiguous "no" from the
  publish-check prompt. Every other outcome — "yes", a malformed reply, an LLM
  error, a missing cleaned question — leaves the row unbrowsable.

  Failing closed means a worker outage degrades to "group questions don't get
  listed", never to "group questions get listed unchecked".

  The row's ANSWER is unaffected: it is already `pooled` and already serves the
  cross-user cache, which never exposes the asker's wording or identity.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{LLM, Prompts, Repo}

  def enqueue(question_log_id) do
    %{question_log_id: question_log_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"question_log_id" => id}}) do
    case Repo.get(QuestionLog, id) do
      nil -> :ok
      ql -> screen(ql)
    end
  end

  # Only a group row that is still unbrowsable and actually has cleaned text is
  # a candidate. Everything else is a no-op — including a non-group row, which
  # must never be demoted by this worker.
  defp screen(%QuestionLog{group_id: gid, browsable: false, cleaned_question: cleaned} = ql)
       when not is_nil(gid) and is_binary(cleaned) do
    if String.trim(cleaned) == "" do
      :ok
    else
      decide(ql, cleaned)
    end
  end

  defp screen(_ql), do: :ok

  defp decide(ql, cleaned) do
    system = Prompts.template("publish_check_system")
    prompt = Prompts.render("publish_check", %{question: cleaned})

    # raw: true — chat/3 decodes a JSON "answer" key and returns "" otherwise, and
    # this prompt returns a bare word.
    case LLM.chat(system, prompt, raw: true) do
      {:ok, reply} -> maybe_publish(ql, reply)
      _ -> :ok
    end
  end

  # Fail closed: ONLY a bare "no" publishes. Anything else — "yes", a hedge, a
  # sentence, empty — leaves the row unbrowsable.
  defp maybe_publish(ql, reply) do
    if reply |> to_string() |> String.trim() |> String.downcase() |> String.trim_trailing(".") ==
         "no" do
      ql |> QuestionLog.changeset(%{browsable: true}) |> Repo.update()
    end

    :ok
  end
end
```

**Adapt `LLM.chat/3`'s real signature** — check it before writing; the `raw: true`
option is required (see the "LLM.chat decode_answer" gotcha: `chat/3` returns `""`
for JSON without an `"answer"` key). Add the Jobs-log reporting the other workers do.

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/workers/publish_check_worker_test.exs`
Expected: PASS.

- [ ] **Step 5: Sabotage-check the fail-closed behaviour**

Change `== "no"` to `!= "yes"`. The garbage-reply and error tests must go RED.
Restore.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/workers/publish_check_worker.ex test/
git commit -m "feat(groups): PublishCheckWorker screens group questions before listing"
```

---

### Task 4: AskWorker wiring

**Files:**
- Modify: `lib/rule_maven/workers/ask_worker.ex` (row insert ~line 168; the
  `mark_pooled` block ~line 374)
- Modify: `lib/rule_maven/groups.ex` (add `contribute_to_community?/1`)
- Test: `test/rule_maven/workers/ask_worker_test.exs`

**Interfaces:**
- Consumes: `PublishCheckWorker.enqueue/1` (Task 3), `QuestionLog.browsable`
  (Task 1).
- Produces: `Groups.contribute_to_community?(group_id) :: boolean` — `true` when
  no group (a non-group ask always contributes).

- [ ] **Step 1: Write the failing tests**

```elixir
test "a group ask is written unbrowsable and enqueues the publish check" do
  # ... perform an ask with group_id set
  assert Repo.reload!(ql).browsable == false
  assert_enqueued worker: RuleMaven.Workers.PublishCheckWorker, args: %{"question_log_id" => ql.id}
end

test "a non-group ask stays browsable and enqueues no publish check" do
  assert Repo.reload!(ql).browsable == true
  refute_enqueued worker: RuleMaven.Workers.PublishCheckWorker
end

test "a skip_normalize group ask never enqueues the publish check" do
  # cleaned_question is nil on this path (normalize never ran; the raw text
  # is pinned as match_text instead) — it must never publish. Belt and
  # suspenders: even if this enqueue guard were ever removed,
  # PublishCheckWorker's own is_binary(cleaned_question) guard would still
  # reject the row, since a skip_normalize row's cleaned_question is nil.
  assert Repo.reload!(ql).browsable == false
  refute_enqueued worker: RuleMaven.Workers.PublishCheckWorker
end

test "a group with contribute_to_community: false does not pool its asks" do
  assert Repo.reload!(ql).pooled == false
  assert Repo.reload!(ql).browsable == false
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/workers/ask_worker_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add the group setting read**

In `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Whether a group contributes its answers to the community cache. `true` for a
  nil group_id — a non-group ask always contributes, as it always has.
  """
  def contribute_to_community?(nil), do: true

  def contribute_to_community?(group_id) do
    case Repo.get(Group, group_id) do
      nil -> true
      group -> group.contribute_to_community
    end
  end
```

- [ ] **Step 4: Write the row unbrowsable (Gates 3 + 4)**

At the row insert (`ask_worker.ex` ~line 168, where `group_id:` is already passed),
add:

```elixir
                   # A group row's question text is unbrowsable until
                   # PublishCheckWorker clears it. A non-group row is browsable, as
                   # it always has been.
                   browsable: is_nil(group_id),
```

Fold the group setting into `never_pool` (Gate 4 — the per-group switch; the
composer toggle in Task 6 sets `never_pool` directly):

```elixir
    never_pool =
      (args["never_pool"] || false) or
        not RuleMaven.Groups.contribute_to_community?(args["group_id"])
```

- [ ] **Step 5: Enqueue the check (Gate 3)**

In the `unless pool_hit? or never_pool do` block, beside the existing
`TagQuestionWorker.enqueue/2`, after `Games.mark_pooled(updated)` succeeds:

```elixir
                            Games.mark_pooled(updated)

                            # A group row's cleaned_question must clear the publish
                            # check before it may be listed publicly. `skip_normalize`
                            # rows are excluded outright: on that path cleaned_question
                            # is nil (normalize never ran) and the raw user text is
                            # pinned as match_text instead, which must never publish.
                            if group_id && not skip_normalize do
                              RuleMaven.Workers.PublishCheckWorker.enqueue(question_log_id)
                            end
```

- [ ] **Step 6: Run tests**

Run: `mix test test/rule_maven/workers/ask_worker_test.exs`
Expected: PASS.

- [ ] **Step 7: Sabotage-check Gate 3**

Remove `and not skip_normalize`. The skip_normalize test must go RED. Restore.

- [ ] **Step 8: Commit**

```bash
git commit -am "feat(groups): group asks are unbrowsable until the publish check clears them"
```

---

### Task 5: Enforcement reads

**Files:**
- Modify: `lib/rule_maven/games.ex` (`unverified_pool_questions/2`, ~line 2328)
- Modify: `lib/rule_maven/workers/direct_promotion_worker.ex` (candidate query, ~line 23)
- Modify: the browse surface(s) that render a listed question's text — find them
  with `rg -n 'unverified_pool_questions' lib/`
- Test: `test/rule_maven/games_test.exs`, `test/rule_maven/workers/direct_promotion_worker_test.exs`

**Interfaces:**
- Consumes: `QuestionLog.browsable` (Task 1).

- [ ] **Step 1: Write the failing tests**

```elixir
test "unverified_pool_questions excludes unbrowsable rows" do
  browsable = question_fixture(pooled: true, browsable: true, game_id: game.id)
  hidden = question_fixture(pooled: true, browsable: false, game_id: game.id)

  ids = game |> Games.unverified_pool_questions() |> Enum.map(& &1.id)
  assert browsable.id in ids
  refute hidden.id in ids
end

test "DirectPromotionWorker never promotes an unbrowsable row" do
  # above the trust floor, with quorum — the ONLY thing stopping it is browsable
  ql = question_fixture(pooled: true, browsable: false, trust_score: 999.0)
  # ... give it a quorum of eligible voters
  assert :ok = perform_job(DirectPromotionWorker, %{})
  assert Repo.reload!(ql).visibility == "private"
end
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — both rows currently come back / the row gets promoted.

- [ ] **Step 3: Add `browsable` to `unverified_pool_questions/2`**

```elixir
        where:
          q.game_id == ^game.id and q.pooled == true and q.browsable == true and
            q.visibility != "community" and
            q.refused == false and q.needs_review == false and q.blocked == false and
```

Update the `@doc` to say that group rows appear only after clearing the publish
check.

- [ ] **Step 4: Add `browsable` to the DirectPromotionWorker candidate query**

```elixir
        where: q.pooled == true and q.browsable == true and q.refused == false and
                 q.visibility != "community",
```

with a comment: a row that may not be listed must not be promoted, since promotion
makes it listable everywhere.

- [ ] **Step 5: Render cleaned text for group rows on browse surfaces**

Find the browse surface(s) with `rg -n 'unverified_pool_questions' lib/`. Wherever
a listed row's question text is rendered, a row with a `group_id` must render
`cleaned_question`, never `question`. Add one helper next to the surface rather
than duplicating the conditional:

```elixir
  # A group row publishes only its scrubbed, normalized form — never the
  # asker's raw wording. A group row without cleaned_question cannot be
  # browsable (the publish check reads cleaned_question, and rejects nil/blank
  # outright — this is also what makes a skip_normalize row unreachable here),
  # so the fallback is unreachable; it is here so a future caller can't
  # accidentally leak raw text.
  defp listed_question(%{group_id: gid, cleaned_question: c}) when not is_nil(gid),
    do: c || "(question withheld)"

  defp listed_question(q), do: q.cleaned_question || q.question
```

Match the existing rendering: check what the surface renders today for non-group
rows and preserve it exactly in the second clause.

- [ ] **Step 6: Run tests**

Run: `mix test test/rule_maven/games_test.exs test/rule_maven/workers/direct_promotion_worker_test.exs`
Expected: PASS.

- [ ] **Step 7: Sabotage-check both gates**

Remove `q.browsable == true` from each query in turn; the matching test must go
RED. Restore.

- [ ] **Step 8: Commit**

```bash
git commit -am "feat(groups): gate browse + auto-promotion on browsable"
```

---

### Task 6: UI — composer toggle, group setting, help

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (the ask composer + both ask
  paths that already pass `group_id:`)
- Modify: `lib/rule_maven_web/live/group_live/show.ex` (group settings)
- Modify: `lib/rule_maven/groups.ex` (add `set_contribute/3`)
- Modify: the `/help` page (find it with `rg -n 'help' lib/rule_maven_web/router.ex`)
- Modify: `priv/static/assets/css/app.css` — **hand-authored, tracked, NO build
  step.** Add real classes; do not use inline styles.
- Test: `test/rule_maven_web/live/group_live/show_test.exs`, `test/rule_maven_web/live/game_live/show_test.exs`

**Interfaces:**
- Consumes: `Groups.contribute_to_community?/1` (Task 4), `never_pool` (existing
  `AskWorker` arg).
- Produces: `Groups.set_contribute(group, actor, bool)` — admin-or-owner gated,
  same authorization shape as the existing `rename/3`.

- [ ] **Step 1: Write the failing tests**

```elixir
test "the keep-in-crew toggle sends never_pool" do
  # with a group active, submit an ask with the toggle checked
  assert_enqueued worker: RuleMaven.Workers.AskWorker, args: %{"never_pool" => true}
end

test "the composer toggle is hidden with no active group" do
  refute html =~ "Keep this in the crew"
end

test "an owner can turn off community contribution" do
  view |> element("#contribute-toggle") |> render_click()
  refute Groups.contribute_to_community?(group.id)
end

test "a plain member cannot change the contribution setting" do
  assert {:error, :unauthorized} = Groups.set_contribute(group, member, false)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL.

- [ ] **Step 3: Add `Groups.set_contribute/3`**

Copy the authorization shape of the existing `rename/3` exactly (owner-or-admin
via `role_at_least?/3`). Do not invent a new authorization path.

- [ ] **Step 4: Add the composer toggle (Gate 4, per ask)**

A checkbox in the ask composer in `show.ex`, rendered **only when
`@active_group_id` is set**, labelled **"Keep this in the crew"** with helper text
*"Don't share this answer with the wider community."* Its value flows into the
existing `never_pool` arg on both ask paths (the two places that already pass
`group_id: socket.assigns[:active_group_id]`).

- [ ] **Step 5: Add the group setting (Gate 4, per group)**

On `/groups/:token`, an owner/admin-only toggle: **"Contribute answers to the
community"**, on by default, with helper text *"Your crew's questions stay private
either way — only the answers are shared, and only after a privacy check."*

- [ ] **Step 6: Update /help**

Document both controls, and state plainly what a group shares: answers feed the
community cache anonymously; question text is published only in scrubbed canonical
form after a privacy check; "Keep this in the crew" seals a question entirely.

- [ ] **Step 7: Run tests + verify at 390px**

Run: `mix test test/rule_maven_web/live/group_live/show_test.exs test/rule_maven_web/live/game_live/show_test.exs`
Expected: PASS. Then check the composer + settings at 390px — no horizontal
scroll, tap targets ≥36px under `pointer: coarse`.

- [ ] **Step 8: Commit**

```bash
git commit -am "feat(groups): keep-in-crew toggle + per-group contribution setting"
```

---

## Deploy

`mix ecto.migrate` (the `browsable` + `contribute_to_community` columns).
