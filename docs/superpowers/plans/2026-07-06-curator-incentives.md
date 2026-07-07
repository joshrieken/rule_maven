# Curator Incentives v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reward voters whose votes match the eventual trust outcome (promotion/verify/demotion) with curator points, bonus ask quota, and badges.

**Architecture:** A new `RuleMaven.Games.Curation` context module owns vote settlement and curator stats. A thin `SettleVotesWorker` (Oban) is enqueued from the three terminal-event sites. Quota bonus is computed at `check_rate_limit` time from settled votes (no stored counters). UI: curator stats panel in Settings profile tab + aggregate flash notice on game page mount.

**Tech Stack:** Phoenix LiveView, Ecto/Postgres, Oban.

**Spec:** `docs/superpowers/specs/2026-07-06-curator-incentives-design.md`

## Global Constraints

- Each vote settles at most once, ever (unsettled-only predicate; first event wins).
- Only votes cast before the event settle (`inserted_at <= event_at`).
- Weight-0 asker self-confirm votes and any author self-vote never settle.
- `curator_points` never affects vote weight or `reputation`.
- Bonus quota cap: Settings key `curator_bonus_cap`, default 20, monthly.
- Badges: Curator = 10 correct, Sharp Eye = 25 correct, Taste Maker = 5 correct upvotes cast before promotion quorum was reached.
- Worker reports to unified Jobs log (`RuleMaven.Jobs.start_run/event/finish_run`).
- `question_votes.inserted_at` is `naive_datetime` — compare with `NaiveDateTime`, not `DateTime`.
- Test output: tee to `./tmp/<log>.log`, delete log when done.

---

### Task 1: Migration + schema fields

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_curator_incentives.exs` (generate with `mix ecto.gen.migration add_curator_incentives`)
- Modify: `lib/rule_maven/games/question_vote.ex`
- Modify: `lib/rule_maven/users/user.ex` (fields around line 11)

**Interfaces:**
- Produces: `question_votes.settled_at :utc_datetime`, `question_votes.settled_outcome :string`; `users.curator_points :integer default 0`, `users.curator_seen_at :utc_datetime`. Schema fields with same names.

- [ ] **Step 1: Generate + write migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddCuratorIncentives do
  use Ecto.Migration

  def change do
    alter table(:question_votes) do
      add :settled_at, :utc_datetime
      add :settled_outcome, :string
    end

    alter table(:users) do
      add :curator_points, :integer, default: 0, null: false
      add :curator_seen_at, :utc_datetime
    end

    # Monthly bonus-quota query: user's correct settles in current month.
    create index(:question_votes, [:user_id, :settled_at],
             where: "settled_outcome = 'correct'",
             name: :question_votes_user_correct_settled_idx
           )
  end
end
```

- [ ] **Step 2: Run migration**

Run: `mix ecto.migrate`
Expected: migration runs clean.

- [ ] **Step 3: Add schema fields**

In `lib/rule_maven/games/question_vote.ex`, after `field :weight, ...`:

```elixir
    field :settled_at, :utc_datetime
    field :settled_outcome, :string
```

Do NOT add them to `cast` in `changeset/2` — settlement writes via `update_all` only, and user input must never set them.

In `lib/rule_maven/users/user.ex`, after `field :reputation, ...`:

```elixir
    field :curator_points, :integer, default: 0
    field :curator_seen_at, :utc_datetime
```

Do NOT add to any user-facing changeset cast list.

- [ ] **Step 4: Compile + commit**

Run: `mix compile --warnings-as-errors`
Expected: clean.

```bash
git add priv/repo/migrations lib/rule_maven/games/question_vote.ex lib/rule_maven/users/user.ex
git commit -m "feat: curator incentive columns on votes and users"
```

---

### Task 2: Curation.settle_votes/3

**Files:**
- Create: `lib/rule_maven/games/curation.ex`
- Test: `test/rule_maven/games/curation_test.exs`

**Interfaces:**
- Consumes: Task 1 columns.
- Produces: `RuleMaven.Games.Curation.settle_votes(%QuestionLog{}, outcome, event_at \\ NaiveDateTime.utc_now())` where `outcome in [:confirmed, :rejected]`; returns `{:ok, {correct_count, incorrect_count}}`. `:confirmed` → up=correct/down=incorrect; `:rejected` → reverse. +1 `curator_points` per correct-settled voter.

- [ ] **Step 1: Write failing tests**

`test/rule_maven/games/curation_test.exs`:

```elixir
defmodule RuleMaven.Games.CurationTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.{Curation, QuestionVote}
  alias RuleMaven.Repo
  alias RuleMaven.Users

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp log(game, author, attrs \\ %{}) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "How does X work?",
            answer: "It works like Y.",
            user_id: author && author.id,
            pooled: true
          },
          attrs
        )
      )

    q
  end

  setup do
    game = game_fixture()
    author = user_fixture("author")
    up_voter = user_fixture("upvoter")
    down_voter = user_fixture("downvoter")
    %{game: game, author: author, up_voter: up_voter, down_voter: down_voter}
  end

  describe "settle_votes/3" do
    test "confirmed: up settles correct (+1 point), down incorrect (0)", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      Games.set_community_vote(q.id, ctx.down_voter.id, "down")

      assert {:ok, {1, 1}} = Curation.settle_votes(q, :confirmed)

      assert Repo.reload!(ctx.up_voter).curator_points == 1
      assert Repo.reload!(ctx.down_voter).curator_points == 0

      up = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      down = Games.get_user_community_vote(q.id, ctx.down_voter.id)
      assert up.settled_outcome == "correct" and up.settled_at
      assert down.settled_outcome == "incorrect" and down.settled_at
    end

    test "rejected: down settles correct, up incorrect", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      Games.set_community_vote(q.id, ctx.down_voter.id, "down")

      assert {:ok, {1, 1}} = Curation.settle_votes(q, :rejected)
      assert Repo.reload!(ctx.down_voter).curator_points == 1
      assert Repo.reload!(ctx.up_voter).curator_points == 0
    end

    test "settles at most once — second event is a no-op", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")

      assert {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
      # Later demotion must not flip or re-award.
      assert {:ok, {0, 0}} = Curation.settle_votes(q, :rejected)

      assert Repo.reload!(ctx.up_voter).curator_points == 1
      vote = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      assert vote.settled_outcome == "correct"
    end

    test "votes cast after the event never settle", ctx do
      q = log(ctx.game, ctx.author)
      event_at = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")

      assert {:ok, {0, 0}} = Curation.settle_votes(q, :confirmed, event_at)
      vote = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      assert is_nil(vote.settled_at)
    end

    test "author self-confirm (weight 0) is excluded", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.author.id, "up")

      assert {:ok, {0, 0}} = Curation.settle_votes(q, :confirmed)
      assert Repo.reload!(ctx.author).curator_points == 0
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/rule_maven/games/curation_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: FAIL — `Curation` module undefined.

- [ ] **Step 3: Implement**

`lib/rule_maven/games/curation.ex`:

```elixir
defmodule RuleMaven.Games.Curation do
  @moduledoc """
  Curator incentives: settle votes against terminal trust events and derive
  voter rewards (curator points, bonus ask quota, badges).

  A vote settles at most once, when its row first reaches a terminal event:
  promotion/verify (`:confirmed` — upvotes were right) or moderation demotion
  (`:rejected` — downvotes were right). Only votes cast before the event
  settle, and author self-votes never do. `curator_points` is deliberately
  separate from `reputation`: it never feeds vote weight, so a vote ring's
  payoff is capped at cosmetic points and bounded bonus quota.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Games.{QuestionLog, QuestionVote}
  alias RuleMaven.Repo
  alias RuleMaven.Users.User

  @default_bonus_cap 20

  @doc """
  Settles all eligible, unsettled votes on a row. `:confirmed` marks upvotes
  correct; `:rejected` marks downvotes correct. Correct-settled voters gain
  one curator point each. Returns `{:ok, {correct_count, incorrect_count}}`.
  Idempotent: already-settled votes are never touched.
  """
  def settle_votes(%QuestionLog{} = q, outcome, event_at \\ NaiveDateTime.utc_now())
      when outcome in [:confirmed, :rejected] do
    correct_value = if outcome == :confirmed, do: "up", else: "down"
    author_id = q.user_id || -1
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base =
      from v in QuestionVote,
        where:
          v.question_log_id == ^q.id and is_nil(v.settled_at) and
            v.user_id != ^author_id and v.weight > 0.0 and
            v.inserted_at <= ^event_at

    Repo.transaction(fn ->
      {_, correct_ids} =
        Repo.update_all(
          from(v in base, where: v.value == ^correct_value, select: v.user_id),
          set: [settled_at: now, settled_outcome: "correct"]
        )

      {incorrect_count, _} =
        Repo.update_all(
          from(v in base, where: v.value != ^correct_value),
          set: [settled_at: now, settled_outcome: "incorrect"]
        )

      correct_ids = correct_ids || []

      # One vote per (row, user), so a flat +1 per settled-correct voter.
      if correct_ids != [] do
        Repo.update_all(from(u in User, where: u.id in ^correct_ids),
          inc: [curator_points: 1]
        )
      end

      {length(correct_ids), incorrect_count}
    end)
  end

  def bonus_cap do
    case RuleMaven.Settings.get("curator_bonus_cap") do
      nil -> @default_bonus_cap
      "" -> @default_bonus_cap
      v ->
        case Integer.parse(to_string(v)) do
          {n, _} -> n
          :error -> @default_bonus_cap
        end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/games/curation_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: 5 tests, 0 failures. Then `rm tmp/curation_test.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games/curation.ex test/rule_maven/games/curation_test.exs
git commit -m "feat: vote settlement with curator points"
```

---

### Task 3: Curator stats, badges, monthly bonus, unseen notices

**Files:**
- Modify: `lib/rule_maven/games/curation.ex`
- Test: `test/rule_maven/games/curation_test.exs` (append)

**Interfaces:**
- Consumes: Task 2 `settle_votes/3`, `bonus_cap/0`.
- Produces:
  - `Curation.curator_stats(user_id)` → `%{points: int, correct: int, incorrect: int, bonus_this_month: int, badges: [%{key: atom, label: String.t()}]}`
  - `Curation.bonus_asks_this_month(user_id)` → int (capped)
  - `Curation.unseen_correct_count(%User{})` → int (correct settles after `curator_seen_at`)
  - `Curation.mark_notices_seen(%User{})` → :ok

- [ ] **Step 1: Append failing tests**

Append to `test/rule_maven/games/curation_test.exs` inside the module:

```elixir
  describe "stats and notices" do
    test "curator_stats counts settles, caps monthly bonus, awards badges", ctx do
      # 11 correct settles → Curator badge (10) but not Sharp Eye (25).
      for i <- 1..11 do
        q = log(ctx.game, ctx.author, %{question: "Q#{i}?"})
        Games.set_community_vote(q.id, ctx.up_voter.id, "up")
        {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
      end

      stats = Curation.curator_stats(ctx.up_voter.id)
      assert stats.points == 11
      assert stats.correct == 11
      assert stats.incorrect == 0
      assert stats.bonus_this_month == 11
      badge_keys = Enum.map(stats.badges, & &1.key)
      assert :curator in badge_keys
      refute :sharp_eye in badge_keys
    end

    test "bonus_asks_this_month is capped at bonus_cap", ctx do
      RuleMaven.Settings.put("curator_bonus_cap", "3")

      for i <- 1..5 do
        q = log(ctx.game, ctx.author, %{question: "Cap#{i}?"})
        Games.set_community_vote(q.id, ctx.up_voter.id, "up")
        {:ok, _} = Curation.settle_votes(q, :confirmed)
      end

      assert Curation.bonus_asks_this_month(ctx.up_voter.id) == 3
    end

    test "unseen_correct_count resets after mark_notices_seen", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      {:ok, _} = Curation.settle_votes(q, :confirmed)

      voter = Repo.reload!(ctx.up_voter)
      assert Curation.unseen_correct_count(voter) == 1

      :ok = Curation.mark_notices_seen(voter)
      assert Curation.unseen_correct_count(Repo.reload!(voter)) == 0
    end
  end
```

Note: if `RuleMaven.Settings.put/2` is not the setter's name, check `lib/rule_maven/settings.ex` for the actual write function and use that.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/rule_maven/games/curation_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: new tests FAIL — functions undefined.

- [ ] **Step 3: Implement in `curation.ex`**

Add below `settle_votes/3`:

```elixir
  @curator_threshold 10
  @sharp_eye_threshold 25
  @taste_maker_threshold 5

  @doc "Aggregate curator stats for the settings panel."
  def curator_stats(user_id) do
    {correct, incorrect} = settled_counts(user_id)
    points = Repo.one(from u in User, where: u.id == ^user_id, select: u.curator_points) || 0

    %{
      points: points,
      correct: correct,
      incorrect: incorrect,
      bonus_this_month: bonus_asks_this_month(user_id),
      badges: badges(user_id, correct)
    }
  end

  defp settled_counts(user_id) do
    rows =
      Repo.all(
        from v in QuestionVote,
          where: v.user_id == ^user_id and not is_nil(v.settled_outcome),
          group_by: v.settled_outcome,
          select: {v.settled_outcome, count()}
      )

    m = Map.new(rows)
    {Map.get(m, "correct", 0), Map.get(m, "incorrect", 0)}
  end

  @doc "Correct settles in the current UTC month, capped at `bonus_cap/0`."
  def bonus_asks_this_month(user_id) do
    month_start =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    n =
      Repo.one(
        from v in QuestionVote,
          where:
            v.user_id == ^user_id and v.settled_outcome == "correct" and
              v.settled_at >= ^month_start,
          select: count()
      ) || 0

    min(n, bonus_cap())
  end

  defp badges(user_id, correct) do
    base =
      [
        correct >= @curator_threshold && %{key: :curator, label: "Curator"},
        correct >= @sharp_eye_threshold && %{key: :sharp_eye, label: "Sharp Eye"}
      ]

    taste =
      taste_maker_count(user_id) >= @taste_maker_threshold &&
        %{key: :taste_maker, label: "Taste Maker"}

    Enum.filter([taste | base], & &1) |> Enum.reverse()
  end

  # Correct upvotes cast while the row still had fewer than `promotion_quorum`
  # earlier votes from other users — i.e. the voter spotted quality early.
  defp taste_maker_count(user_id) do
    quorum = RuleMaven.Games.Trust.promotion_quorum()

    Repo.one(
      from v in QuestionVote,
        where:
          v.user_id == ^user_id and v.settled_outcome == "correct" and v.value == "up" and
            fragment(
              "(SELECT COUNT(*) FROM question_votes v2 WHERE v2.question_log_id = ? AND v2.user_id != ? AND v2.inserted_at < ?) < ?",
              v.question_log_id,
              ^user_id,
              v.inserted_at,
              ^quorum
            ),
        select: count()
    ) || 0
  end

  @doc "Correct settles the user hasn't been shown yet (after curator_seen_at)."
  def unseen_correct_count(%User{id: id, curator_seen_at: seen_at}) do
    query =
      from v in QuestionVote,
        where: v.user_id == ^id and v.settled_outcome == "correct",
        select: count()

    query = if seen_at, do: from(v in query, where: v.settled_at > ^seen_at), else: query
    Repo.one(query) || 0
  end

  @doc "Advance the notice cursor to now."
  def mark_notices_seen(%User{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^id), set: [curator_seen_at: now])
    :ok
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/games/curation_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: all pass. Then `rm tmp/curation_test.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games/curation.ex test/rule_maven/games/curation_test.exs
git commit -m "feat: curator stats, badges, monthly bonus, unseen notices"
```

---

### Task 4: SettleVotesWorker + event-site hooks

**Files:**
- Create: `lib/rule_maven/workers/settle_votes_worker.ex`
- Modify: `lib/rule_maven/workers/direct_promotion_worker.ex` (`promote/1`, ~line 96)
- Modify: `lib/rule_maven/games.ex` (`do_verify/1` ~line 1796, `demote_user_answers/1` ~line 1856)
- Test: `test/rule_maven/workers/settle_votes_worker_test.exs`

**Interfaces:**
- Consumes: `Curation.settle_votes/3`; `RuleMaven.Jobs.start_run/2..4`, `event/4`, `finish_run/3`.
- Produces: `SettleVotesWorker.enqueue(question_log_id, outcome)` with `outcome in [:confirmed, :rejected]` — captures `event_at` at enqueue time. Args: `%{"question_log_id" => id, "outcome" => "confirmed"|"rejected", "event_at" => iso8601}`.

- [ ] **Step 1: Write failing test**

`test/rule_maven/workers/settle_votes_worker_test.exs`:

```elixir
defmodule RuleMaven.Workers.SettleVotesWorkerTest do
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Workers.SettleVotesWorker

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

    u
  end

  test "perform settles votes in the given direction" do
    game = game_fixture()
    author = user_fixture("author")
    voter = user_fixture("voter")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "Worker Q?",
        answer: "A.",
        user_id: author.id,
        pooled: true
      })

    Games.set_community_vote(q.id, voter.id, "up")

    assert :ok =
             perform_job(SettleVotesWorker, %{
               "question_log_id" => q.id,
               "outcome" => "confirmed",
               "event_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
             })

    assert Repo.reload!(voter).curator_points == 1
  end

  test "perform is a no-op for a missing row" do
    assert :ok =
             perform_job(SettleVotesWorker, %{
               "question_log_id" => -1,
               "outcome" => "confirmed",
               "event_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
             })
  end

  test "enqueue inserts a job with event_at" do
    game = game_fixture()

    {:ok, q} =
      Games.log_question(%{game_id: game.id, question: "E?", answer: "A.", pooled: true})

    SettleVotesWorker.enqueue(q.id, :confirmed)

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "confirmed"}
    )
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/rule_maven/workers/settle_votes_worker_test.exs 2>&1 | tee tmp/settle_test.log`
Expected: FAIL — worker undefined.

- [ ] **Step 3: Implement worker**

`lib/rule_maven/workers/settle_votes_worker.ex`:

```elixir
defmodule RuleMaven.Workers.SettleVotesWorker do
  @moduledoc """
  Settles a row's votes after a terminal trust event (promotion/verify →
  `confirmed`, moderation demotion → `rejected`). `event_at` is captured at
  enqueue time so votes cast after the event never settle even if the job
  runs late. Settlement itself is idempotent, so retries are safe.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias RuleMaven.Games.{Curation, QuestionLog}
  alias RuleMaven.Jobs
  alias RuleMaven.Repo

  def enqueue(question_log_id, outcome) when outcome in [:confirmed, :rejected] do
    %{
      question_log_id: question_log_id,
      outcome: to_string(outcome),
      event_at: NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, id: oban_id}) do
    %{"question_log_id" => id, "outcome" => outcome, "event_at" => event_at_iso} = args

    case Repo.get(QuestionLog, id) do
      nil ->
        :ok

      q ->
        {:ok, event_at} = NaiveDateTime.from_iso8601(event_at_iso)

        run =
          Jobs.start_run("settle_votes", {"game", q.game_id}, "Settle votes ##{id}",
            oban_job_id: oban_id
          )

        {:ok, {correct, incorrect}} =
          Curation.settle_votes(q, String.to_existing_atom(outcome), event_at)

        Jobs.finish_run(run, "ok", "#{outcome}: #{correct} correct, #{incorrect} incorrect")
        :ok
    end
  end
end
```

- [ ] **Step 4: Run worker tests**

Run: `mix test test/rule_maven/workers/settle_votes_worker_test.exs 2>&1 | tee tmp/settle_test.log`
Expected: 3 tests pass.

- [ ] **Step 5: Hook the three event sites**

(a) `lib/rule_maven/workers/direct_promotion_worker.ex`, in `promote/1` after the `Repo.update_all` (keep existing embed/reputation lines):

```elixir
    RuleMaven.Workers.SettleVotesWorker.enqueue(best.id, :confirmed)
```

(b) `lib/rule_maven/games.ex` `do_verify/1` — inside the `with`, after `finalize_verify_toggle` succeeds. Change:

```elixir
    with {:ok, updated} <- Repo.update(QuestionLog.changeset(q, attrs)) do
      RuleMaven.Workers.SettleVotesWorker.enqueue(updated.id, :confirmed)
      finalize_verify_toggle(updated)
    end
```

(Only `do_verify` — NOT `do_unverify` and NOT `demote_verified_duplicate`; retracting a verify is not a terminal negative event per spec.)

(c) `lib/rule_maven/games.ex` `demote_user_answers/1` — inside the `Enum.each` over rows, after `recompute_trust`:

```elixir
      RuleMaven.Games.Trust.recompute_trust(updated)
      RuleMaven.Workers.SettleVotesWorker.enqueue(updated.id, :rejected)
```

- [ ] **Step 6: Integration assertions**

Append to `test/rule_maven/workers/settle_votes_worker_test.exs`:

```elixir
  test "toggle_verified enqueues a confirmed settle" do
    game = game_fixture()
    author = user_fixture("vauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "V?",
        answer: "A.",
        user_id: author.id,
        pooled: true
      })

    {:ok, _} = Games.toggle_verified(q)

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "confirmed"}
    )
  end

  test "demote_user_answers enqueues rejected settles" do
    game = game_fixture()
    author = user_fixture("dauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "D?",
        answer: "A.",
        user_id: author.id,
        pooled: true,
        visibility: "community"
      })

    assert Games.demote_user_answers(author.id) == 1

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "rejected"}
    )
  end
```

- [ ] **Step 7: Run full related tests**

Run: `mix test test/rule_maven/workers/settle_votes_worker_test.exs test/rule_maven/trust_test.exs test/rule_maven/moderation_test.exs test/rule_maven/workers/direct_promotion_worker_test.exs 2>&1 | tee tmp/settle_test.log`
Expected: all pass (existing trust/moderation/promotion tests must not break; if a moderation or verify test fails on Oban insert, check whether that path runs outside a sandbox — Oban.insert works under manual testing, so this should be fine). Then `rm tmp/settle_test.log`.

- [ ] **Step 8: Commit**

```bash
git add lib/rule_maven/workers/settle_votes_worker.ex lib/rule_maven/workers/direct_promotion_worker.ex lib/rule_maven/games.ex test/rule_maven/workers/settle_votes_worker_test.exs
git commit -m "feat: settle votes on promotion, verify, and demotion events"
```

---

### Task 5: Bonus quota in check_rate_limit

**Files:**
- Modify: `lib/rule_maven/games.ex` (`check_rate_limit/1`, ~line 1976)
- Test: `test/rule_maven/games/curation_test.exs` (append)

**Interfaces:**
- Consumes: `Curation.bonus_asks_this_month/1`.
- Produces: monthly limit = `(user.monthly_quota || 200) + bonus`.

- [ ] **Step 1: Append failing test**

Append to `test/rule_maven/games/curation_test.exs`:

```elixir
  describe "quota bonus" do
    test "correct settles raise the monthly quota", ctx do
      # Give the voter a base quota of 0 so any allowance comes from the bonus.
      Repo.update_all(
        from(u in RuleMaven.Users.User, where: u.id == ^ctx.up_voter.id),
        set: [monthly_quota: 0, email_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      voter = Repo.reload!(ctx.up_voter)
      assert {:error, msg} = Games.check_rate_limit(voter)
      assert msg =~ "Monthly question quota reached (0)"

      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, voter.id, "up")
      {:ok, _} = Curation.settle_votes(q, :confirmed)

      assert :ok = Games.check_rate_limit(Repo.reload!(voter))
    end
  end
```

Note: if `check_rate_limit` trips the daily/weekly limits first in this fixture state, that means the user has recent billable rows — they don't here, so daily/weekly pass at 0 usage.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/rule_maven/games/curation_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: new test FAILS (quota stays 0 after settle).

- [ ] **Step 3: Implement**

In `lib/rule_maven/games.ex` `check_rate_limit/1`, replace:

```elixir
      # Monthly is the per-user, admin-tunable quota — not a global setting.
      monthly_limit = user.monthly_quota || 200
```

with:

```elixir
      # Monthly is the per-user, admin-tunable quota — not a global setting —
      # plus this month's earned curator bonus (capped in Curation).
      monthly_limit =
        (user.monthly_quota || 200) +
          RuleMaven.Games.Curation.bonus_asks_this_month(user.id)
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/games/curation_test.exs test/rule_maven/games/rate_limit_house_rules_test.exs 2>&1 | tee tmp/curation_test.log`
Expected: all pass. Then `rm tmp/curation_test.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games/curation_test.exs
git commit -m "feat: curator bonus asks extend monthly quota"
```

---

### Task 6: Curator stats panel in Settings

**Files:**
- Modify: `lib/rule_maven_web/live/settings_live.ex` (mount ~line 54; profile section starts ~line 453)

**Interfaces:**
- Consumes: `Curation.curator_stats/1`, `Curation.bonus_cap/0`.
- Produces: `@curator_stats` assign; "Curator" card in the profile tab.

- [ ] **Step 1: Assign stats in mount**

In `mount/3`, add to the existing `assign(...)` chain (current user is in `socket.assigns.current_user`):

```elixir
      curator_stats:
        RuleMaven.Games.Curation.curator_stats(socket.assigns.current_user.id),
      curator_bonus_cap: RuleMaven.Games.Curation.bonus_cap(),
```

- [ ] **Step 2: Render panel**

Inside the profile tab section (the `<section ...@tab == "profile"...>` starting ~line 453), after the existing profile content but before that section's closing `</section>`, add:

```heex
          <div style="margin-top:1.25rem;border-top:1px solid var(--border);padding-top:1rem">
            <h3 style="font-size:0.9rem;font-weight:700;margin:0 0 0.5rem 0">Curator</h3>
            <p style="font-size:0.82rem;color:var(--text-muted);margin:0 0 0.75rem 0">
              When an answer you voted on is later confirmed or removed, your vote "settles".
              Correct votes earn curator points and bonus questions.
            </p>
            <div style="display:flex;gap:1.5rem;flex-wrap:wrap;font-size:0.85rem">
              <div><strong>{@curator_stats.points}</strong> curator points</div>
              <div>
                <strong>{@curator_stats.correct}</strong> correct /
                <strong>{@curator_stats.incorrect}</strong> incorrect settled votes
              </div>
              <div>
                <strong>{@curator_stats.bonus_this_month}</strong>/{@curator_bonus_cap}
                bonus questions this month
              </div>
            </div>
            <div :if={@curator_stats.badges != []} style="margin-top:0.6rem;display:flex;gap:0.5rem;flex-wrap:wrap">
              <span
                :for={badge <- @curator_stats.badges}
                style="font-size:0.75rem;font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.6rem;background:var(--bg-muted, var(--bg-surface))"
              >
                🏅 {badge.label}
              </span>
            </div>
          </div>
```

Match surrounding inline-style conventions; adjust CSS var names to ones already used in this file if `--bg-muted` doesn't exist (grep the file for `var(--` and reuse).

- [ ] **Step 3: Compile + smoke-check**

Run: `mix compile --warnings-as-errors`
Expected: clean. (Minor UI change — no browser verification per standing rule.)

- [ ] **Step 4: Commit**

```bash
git add lib/rule_maven_web/live/settings_live.ex
git commit -m "feat: curator stats panel in settings profile tab"
```

---

### Task 7: Settlement notice flash on game page

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (`mount/3`, line 11)
- Test: none new (flash path covered by existing flash rendering; logic delegated to tested `Curation` functions). Compile + existing game show LiveView tests must pass.

**Interfaces:**
- Consumes: `Curation.unseen_correct_count/1`, `Curation.mark_notices_seen/1`.

- [ ] **Step 1: Add notice to mount**

In `lib/rule_maven_web/live/game_live/show.ex` `mount/3`, wrap the socket before the assign chain:

```elixir
  def mount(_params, session, socket) do
    socket = maybe_curator_notice(socket)

    {:ok,
     assign(socket,
       ...existing assigns unchanged...
```

And add at the bottom of the module (near other private helpers):

```elixir
  # One aggregate toast per batch of newly settled correct votes. Only on the
  # connected mount so it fires once, not on the dead render too.
  defp maybe_curator_notice(socket) do
    user = socket.assigns.current_user

    with true <- connected?(socket),
         n when n > 0 <- RuleMaven.Games.Curation.unseen_correct_count(user) do
      RuleMaven.Games.Curation.mark_notices_seen(user)

      msg =
        if n == 1 do
          "1 of your votes was confirmed — +1 curator point, +1 bonus question this month."
        else
          "#{n} of your votes were confirmed — +#{n} curator points, +#{n} bonus questions this month."
        end

      Phoenix.LiveView.put_flash(socket, :info, msg)
    else
      _ -> socket
    end
  end
```

(The bonus phrasing overstates when the user is past the monthly cap; acceptable v1 copy — points are always accurate.)

- [ ] **Step 2: Compile + run game show tests**

Run: `mix compile --warnings-as-errors && mix test test/rule_maven_web 2>&1 | tee tmp/web_test.log`
Expected: clean compile, existing web tests pass. Then `rm tmp/web_test.log`.

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat: aggregate curator settlement notice on game page"
```

---

### Task 8: Full suite + wrap-up

- [ ] **Step 1: Full test run**

Run: `mix test 2>&1 | tee tmp/full_test.log`
Expected: 0 failures. Fix anything broken. Then `rm tmp/full_test.log`.

- [ ] **Step 2: Format check**

Run: `mix format --check-formatted || mix format`
Commit any formatting changes.
