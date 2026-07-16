# Player Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give new players a first-run "aha → reward" sequence — a Getting Started panel that surfaces the XP/level progression ladder (primary) plus streak, crew, and badge milestones, backed by a one-time first-answer progression card.

**Architecture:** A `PlayerOnboarding` context derives milestone states from existing data (`mastery_events`, `game_mastery`, `Curation`, `Groups`) and one new piece of state: a daily streak on `users`. A shared function component renders the panel on the games index and game show. The first-answer card rides the existing `{:mastery_awarded, …}` PubSub broadcast — no new transport, no JS.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/Postgres, ExUnit.

## Global Constraints

- **Mobile-first, 390px:** every UI change verified at 390px; panel must never push the ask box below the fold (collapsed chip on coarse-pointer).
- **Zero warnings, zero failures:** no compiler warnings, no red tests — including pre-existing.
- **Contrast floors (WCAG):** panel fills/text pass the contrast tests; fix the fill, not just the text.
- **Button system:** reuse shared `btn-*` classes; one primary CTA per row; no fresh inline button styles.
- **"Ready" terminology:** user-facing wording is "Ready"; internal `playable` code stays.
- **No ids in URLs:** crew invite uses the existing `/groups/join/:code` invite_code path; no raw ids in navigation.
- **Run only necessary tests:** run only the files touched here; tee output to `./tmp/onboarding-test.log`; never run the full suite.
- **Help + tours upkeep:** user-facing feature must add a note to `/help`.
- **Level curve (verbatim):** `threshold(n) = 25·n·(n+1)` → Level 1 @ 50 XP, Level 2 @ 150 XP. `@ask_mastery_xp = 15`.

---

## File Structure

- **Create** `priv/repo/migrations/<ts>_add_streak_to_users.exs` — 3 streak columns.
- **Modify** `lib/rule_maven/users/user.ex` — schema fields + `streak_changeset/2`.
- **Modify** `lib/rule_maven/users.ex` — `bump_streak/2` (idempotent per UTC day).
- **Modify** `lib/rule_maven/progress.ex` — `best_level/1`, `has_award?/1`; hook streak bump + `first_award` into `award/5`.
- **Modify** `lib/rule_maven/workers/ask_worker.ex` — thread `first_award` + `progress` through the broadcast.
- **Create** `lib/rule_maven/player_onboarding.ex` — `summary/1` + `Milestone` struct.
- **Create** `lib/rule_maven_web/live/game_live/onboarding_panel.ex` — `panel/1` + `first_answer_card/1` function components.
- **Modify** `lib/rule_maven_web/live/game_live/index.ex` — mount assign, render panel, toggle event.
- **Modify** `lib/rule_maven_web/live/game_live/show.ex` — mount assign, render panel, toggle event, first-answer card via `handle_info`, dismiss event.
- **Modify** `lib/rule_maven_web/controllers/page_html/help.html.heex` — Getting Started note.
- **Tests:** `test/rule_maven/users_test.exs`, `test/rule_maven/progress_test.exs`, `test/rule_maven/player_onboarding_test.exs`, `test/rule_maven_web/live/game_live/onboarding_panel_test.exs`.

---

### Task 1: Streak columns migration

**Files:**
- Create: `priv/repo/migrations/<ts>_add_streak_to_users.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddStreakToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_active_on, :date
      add :current_streak, :integer, default: 0, null: false
      add :longest_streak, :integer, default: 0, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration**
Run: `mix ecto.migrate`
Expected: creates 3 columns, no error.

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations
git commit -m "feat(onboarding): add daily streak columns to users"
```

---

### Task 2: User schema fields + streak changeset

**Files:**
- Modify: `lib/rule_maven/users/user.ex:24` (schema block near `tours_seen`)
- Test: `test/rule_maven/users_test.exs`

**Interfaces:**
- Produces: `User.streak_changeset(user, %{last_active_on, current_streak, longest_streak})`; schema fields `:last_active_on :date`, `:current_streak :integer`, `:longest_streak :integer`.

- [ ] **Step 1: Write failing test**

```elixir
# test/rule_maven/users_test.exs
test "streak_changeset casts the three streak fields" do
  user = %RuleMaven.Users.User{}
  cs = RuleMaven.Users.User.streak_changeset(user, %{
    last_active_on: ~D[2026-07-16], current_streak: 3, longest_streak: 5
  })
  assert cs.valid?
  assert Ecto.Changeset.get_change(cs, :current_streak) == 3
end
```

- [ ] **Step 2: Run test, verify fails**
Run: `mix test test/rule_maven/users_test.exs -o tmp/onboarding-test.log`
Expected: FAIL — `streak_changeset/2` undefined.

- [ ] **Step 3: Add schema fields**
In the `schema "users"` block (beside `tours_seen`), add:

```elixir
field :last_active_on, :date
field :current_streak, :integer, default: 0
field :longest_streak, :integer, default: 0
```

- [ ] **Step 4: Add changeset**

```elixir
@doc "Casts the daily-streak fields. Used by Users.bump_streak/2."
def streak_changeset(user, attrs) do
  user
  |> cast(attrs, [:last_active_on, :current_streak, :longest_streak])
  |> validate_number(:current_streak, greater_than_or_equal_to: 0)
  |> validate_number(:longest_streak, greater_than_or_equal_to: 0)
end
```

- [ ] **Step 5: Run test, verify passes**
Run: `mix test test/rule_maven/users_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/users/user.ex test/rule_maven/users_test.exs
git commit -m "feat(onboarding): streak fields + changeset on User"
```

---

### Task 3: `Users.bump_streak/2` (idempotent per UTC day)

**Files:**
- Modify: `lib/rule_maven/users.ex`
- Test: `test/rule_maven/users_test.exs`

**Interfaces:**
- Consumes: `User.streak_changeset/2` (Task 2).
- Produces: `Users.bump_streak(user_id :: integer, today :: Date.t()) :: :ok`. Rules: `last_active_on` nil → 1; == today → unchanged; == today−1 → +1; older → reset to 1. `longest_streak = max(longest, current)`.

- [ ] **Step 1: Write failing tests**

```elixir
# test/rule_maven/users_test.exs
describe "bump_streak/2" do
  setup do
    {:ok, user: user_fixture()}  # existing fixture
  end

  test "first ever activity starts streak at 1", %{user: user} do
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-16])
    u = RuleMaven.Users.get_user!(user.id)
    assert u.current_streak == 1 and u.longest_streak == 1
    assert u.last_active_on == ~D[2026-07-16]
  end

  test "same-day activity does not bump", %{user: user} do
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-16])
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-16])
    assert RuleMaven.Users.get_user!(user.id).current_streak == 1
  end

  test "consecutive day increments and tracks longest", %{user: user} do
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-16])
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-17])
    u = RuleMaven.Users.get_user!(user.id)
    assert u.current_streak == 2 and u.longest_streak == 2
  end

  test "a gap resets current but preserves longest", %{user: user} do
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-16])
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-17])
    :ok = RuleMaven.Users.bump_streak(user.id, ~D[2026-07-20])
    u = RuleMaven.Users.get_user!(user.id)
    assert u.current_streak == 1 and u.longest_streak == 2
  end
end
```

- [ ] **Step 2: Run tests, verify fail**
Run: `mix test test/rule_maven/users_test.exs`
Expected: FAIL — `bump_streak/2` undefined.

- [ ] **Step 3: Implement**

```elixir
@doc """
Bumps the user's daily streak for `today` (a UTC date). Idempotent per day:
same-day calls are no-ops. Called once per awarded answer from Progress.award/5.
"""
def bump_streak(user_id, today) do
  user = Repo.get!(User, user_id)
  {current, longest} = next_streak(user, today)

  {1, _} =
    Repo.update_all(from(u in User, where: u.id == ^user_id),
      set: [last_active_on: today, current_streak: current, longest_streak: longest]
    )

  :ok
end

defp next_streak(%User{last_active_on: nil}, _today), do: {1, 1}

defp next_streak(%User{last_active_on: last} = user, today) do
  current =
    cond do
      last == today -> user.current_streak
      Date.diff(today, last) == 1 -> user.current_streak + 1
      true -> 1
    end

  {current, max(user.longest_streak || 0, current)}
end
```

- [ ] **Step 4: Run tests, verify pass**
Run: `mix test test/rule_maven/users_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/users.ex test/rule_maven/users_test.exs
git commit -m "feat(onboarding): idempotent daily streak bump"
```

---

### Task 4: `Progress.best_level/1` + `has_award?/1`

**Files:**
- Modify: `lib/rule_maven/progress.ex`
- Test: `test/rule_maven/progress_test.exs`

**Interfaces:**
- Produces: `Progress.best_level(user_id) :: non_neg_integer` (max `game_mastery.level`, 0 if none); `Progress.has_award?(user_id) :: boolean` (any `mastery_events` row).

- [ ] **Step 1: Write failing tests**

```elixir
# test/rule_maven/progress_test.exs
test "best_level is 0 and has_award? false for a fresh user" do
  user = user_fixture()
  assert RuleMaven.Progress.best_level(user.id) == 0
  refute RuleMaven.Progress.has_award?(user.id)
end

test "best_level reflects the highest game level after awards" do
  user = user_fixture()
  game = game_fixture()
  # 4 distinct awards → 60 XP → Level 1
  for k <- 1..4, do: RuleMaven.Progress.award_ask(user.id, game.id, "src-#{k}")
  assert RuleMaven.Progress.has_award?(user.id)
  assert RuleMaven.Progress.best_level(user.id) == 1
end
```

- [ ] **Step 2: Run tests, verify fail**
Run: `mix test test/rule_maven/progress_test.exs`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement (add near `get_mastery/2`)**

```elixir
@doc "Highest level the user has reached across all their games (0 if none)."
def best_level(user_id) do
  Repo.one(from(m in GameMastery, where: m.user_id == ^user_id, select: max(m.level))) || 0
end

@doc "True once the user has earned at least one mastery award."
def has_award?(user_id) do
  Repo.exists?(from(e in MasteryEvent, where: e.user_id == ^user_id))
end
```

- [ ] **Step 4: Run tests, verify pass**
Run: `mix test test/rule_maven/progress_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/progress.ex test/rule_maven/progress_test.exs
git commit -m "feat(onboarding): Progress.best_level/1 + has_award?/1"
```

---

### Task 5: Hook streak bump + `first_award` into `Progress.award/5`

**Files:**
- Modify: `lib/rule_maven/progress.ex:59-63` (the `{:ok, _event} ->` branch of `award/5`)
- Test: `test/rule_maven/progress_test.exs`

**Interfaces:**
- Consumes: `Users.bump_streak/2` (Task 3), `has_award?` count logic.
- Produces: `award_ask/3` `{:awarded, result}` where `result` now also has `first_award: boolean`. The user's streak is bumped exactly once per UTC day inside the award transaction.

- [ ] **Step 1: Write failing tests**

```elixir
# test/rule_maven/progress_test.exs
test "first award flags first_award: true and starts the streak" do
  user = user_fixture()
  game = game_fixture()
  {:awarded, r1} = RuleMaven.Progress.award_ask(user.id, game.id, "a")
  assert r1.first_award
  assert RuleMaven.Users.get_user!(user.id).current_streak == 1

  {:awarded, r2} = RuleMaven.Progress.award_ask(user.id, game.id, "b")
  refute r2.first_award
end
```

- [ ] **Step 2: Run test, verify fails**
Run: `mix test test/rule_maven/progress_test.exs`
Expected: FAIL — `result` has no `:first_award` key (assert on `r1.first_award` raises/false).

- [ ] **Step 3: Modify the award transaction**
Add `alias RuleMaven.Users` at the top of `progress.ex` if not present. Change the `{:ok, _event} ->` branch:

```elixir
{:ok, _event} ->
  bump_global(user_id)
  Users.bump_streak(user_id, Date.utc_today())

  first_award =
    Repo.aggregate(from(e in MasteryEvent, where: e.user_id == ^user_id), :count) == 1

  user_id
  |> apply_mastery(game_id, xp_delta)
  |> Map.put(:first_award, first_award)
```

(Confirm the `award/5` `@doc` return shape comment gains `first_award: boolean` — keep docs honest.)

- [ ] **Step 4: Run tests, verify pass**
Run: `mix test test/rule_maven/progress_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/progress.ex test/rule_maven/progress_test.exs
git commit -m "feat(onboarding): streak bump + first_award flag in award/5"
```

---

### Task 6: `PlayerOnboarding` context — `summary/1`

**Files:**
- Create: `lib/rule_maven/player_onboarding.ex`
- Test: `test/rule_maven/player_onboarding_test.exs`

**Interfaces:**
- Consumes: `Progress.has_award?/1`, `Progress.best_level/1`, `Progress.get_mastery/2` is not needed here; `Curation.curator_stats/1`, `Groups.list_for_user/1`, user streak fields.
- Produces:
  - `PlayerOnboarding.summary(user) :: %{milestones: [Milestone.t()], done: non_neg_integer, total: non_neg_integer, all_complete?: boolean, current_streak: non_neg_integer}`
  - `%PlayerOnboarding.Milestone{key, label, why, done?, cta}` where `key ∈ [:first_question, :level_1, :badge, :crew, :streak]`, `cta` is `nil` or `%{label, kind}` with `kind ∈ [:ask, :crew, :help]`.

- [ ] **Step 1: Write failing tests**

```elixir
# test/rule_maven/player_onboarding_test.exs
alias RuleMaven.PlayerOnboarding

test "fresh user: nothing done, five milestones, ask CTA on level_1" do
  user = user_fixture()
  s = PlayerOnboarding.summary(user)
  assert s.total == 5
  assert s.done == 0
  refute s.all_complete?
  first_q = Enum.find(s.milestones, &(&1.key == :first_question))
  refute first_q.done?
  level = Enum.find(s.milestones, &(&1.key == :level_1))
  assert level.cta.kind == :ask
end

test "an awarded answer completes first_question and starts the streak" do
  user = user_fixture()
  game = game_fixture()
  RuleMaven.Progress.award_ask(user.id, game.id, "x")
  user = RuleMaven.Users.get_user!(user.id)
  s = PlayerOnboarding.summary(user)
  assert Enum.find(s.milestones, &(&1.key == :first_question)).done?
  assert s.current_streak == 1
end
```

- [ ] **Step 2: Run tests, verify fail**
Run: `mix test test/rule_maven/player_onboarding_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the context**

```elixir
defmodule RuleMaven.PlayerOnboarding do
  @moduledoc """
  Derives a new player's onboarding milestones from existing progression data
  plus the daily streak. Read-only; never gates play. See
  docs/superpowers/specs/2026-07-16-player-onboarding-design.md.
  """
  alias RuleMaven.{Progress, Groups}
  alias RuleMaven.Games.Curation

  defmodule Milestone do
    @moduledoc false
    @enforce_keys [:key, :label, :why, :done?]
    defstruct [:key, :label, :why, :done?, :cta]
  end

  @doc """
  Milestone summary for `user`. `cta` is present only on the first not-done
  milestone that has an actionable next step, so the panel highlights one CTA.
  """
  def summary(nil), do: %{milestones: [], done: 0, total: 0, all_complete?: false, current_streak: 0}

  def summary(user) do
    milestones = [
      %Milestone{key: :first_question, label: "Ask your first question",
        why: "See a grounded, cited answer in seconds.",
        done?: Progress.has_award?(user.id), cta: cta(:ask, "Ask a question")},
      %Milestone{key: :level_1, label: "Reach Level 1",
        why: "About four confident answers unlocks your first level.",
        done?: Progress.best_level(user.id) >= 1, cta: cta(:ask, "Keep asking")},
      %Milestone{key: :streak, label: "Start a daily streak",
        why: "Come back tomorrow to keep it alive.",
        done?: (user.current_streak || 0) >= 2, cta: nil},
      %Milestone{key: :crew, label: "Invite your crew",
        why: "Shared answers, shared mastery at your table.",
        done?: Groups.list_for_user(user) != [], cta: cta(:crew, "Invite your crew")},
      %Milestone{key: :badge, label: "Earn a badge",
        why: "Good questions earn points, badges, and bonus quota.",
        done?: Curation.curator_stats(user.id).badges != [], cta: cta(:help, "How it works")}
    ]

    milestones = highlight_first_open(milestones)
    done = Enum.count(milestones, & &1.done?)

    %{
      milestones: milestones,
      done: done,
      total: length(milestones),
      all_complete?: done == length(milestones),
      current_streak: user.current_streak || 0
    }
  end

  defp cta(kind, label), do: %{kind: kind, label: label}

  # Keep a CTA only on the first not-done milestone; clear the rest so the panel
  # shows exactly one active next step.
  defp highlight_first_open(milestones) do
    {out, _} =
      Enum.map_reduce(milestones, false, fn m, highlighted? ->
        cond do
          m.done? -> {%{m | cta: nil}, highlighted?}
          highlighted? -> {%{m | cta: nil}, true}
          true -> {m, true}
        end
      end)

    out
  end
end
```

- [ ] **Step 4: Run tests, verify pass**
Run: `mix test test/rule_maven/player_onboarding_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/player_onboarding.ex test/rule_maven/player_onboarding_test.exs
git commit -m "feat(onboarding): PlayerOnboarding.summary/1 milestone context"
```

---

### Task 7: Onboarding panel + first-answer card components

**Files:**
- Create: `lib/rule_maven_web/live/game_live/onboarding_panel.ex`
- Test: `test/rule_maven_web/live/game_live/onboarding_panel_test.exs`

**Interfaces:**
- Consumes: `PlayerOnboarding.summary/1` output (Task 6).
- Produces:
  - `RuleMavenWeb.GameLive.OnboardingPanel.panel/1` — attrs: `summary` (map), `collapsed` (bool), `id` (string, distinguishes index vs show mount). Emits `phx-click="toggle_getting_started"` on the caret and `phx-click="onboarding_cta"` with `phx-value-kind` on CTAs.
  - `RuleMavenWeb.GameLive.OnboardingPanel.first_answer_card/1` — attrs: `card` (`%{answers_to_next, xp_delta}` or `nil`). Emits `phx-click="dismiss_first_answer_card"`.

- [ ] **Step 1: Write failing render tests**

```elixir
# test/rule_maven_web/live/game_live/onboarding_panel_test.exs
import Phoenix.LiveViewTest
alias RuleMavenWeb.GameLive.OnboardingPanel
alias RuleMaven.PlayerOnboarding

test "panel shows N/5 and a single active CTA" do
  summary = PlayerOnboarding.summary(user_fixture())
  html = render_component(&OnboardingPanel.panel/1, summary: summary, collapsed: false, id: "gs-test")
  assert html =~ "Getting Started"
  assert html =~ "0/5"
  # exactly one CTA button rendered
  assert length(Regex.scan(~r/onboarding_cta/, html)) == 1
end

test "collapsed panel renders only the summary chip" do
  summary = PlayerOnboarding.summary(user_fixture())
  html = render_component(&OnboardingPanel.panel/1, summary: summary, collapsed: true, id: "gs-test")
  assert html =~ "toggle_getting_started"
  refute html =~ "Ask your first question"
end

test "first_answer_card renders answers-to-next and dismiss" do
  html = render_component(&OnboardingPanel.first_answer_card/1,
    card: %{answers_to_next: 3, xp_delta: 15})
  assert html =~ "+15 XP"
  assert html =~ "3 more"
  assert html =~ "dismiss_first_answer_card"
end

test "first_answer_card renders nothing when card is nil" do
  html = render_component(&OnboardingPanel.first_answer_card/1, card: nil)
  assert String.trim(html) == ""
end
```

- [ ] **Step 2: Run tests, verify fail**
Run: `mix test test/rule_maven_web/live/game_live/onboarding_panel_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the components**
Follow existing `sub_bar.ex` component idiom (attrs, `~H`, shared `btn-*` classes, mobile classes). Panel: header with `#{@summary.done}/#{@summary.total}` + caret; when not collapsed, a list of rows keyed by milestone; done rows muted + struck, the single milestone carrying a `cta` gets a `btn-primary` button, others plain. Collapsed: a single line `Getting Started #{done}/#{total} ›` that is the toggle. `first_answer_card/1`: returns empty for `nil`, else a dismissible card with `+#{@card.xp_delta} XP` and `#{@card.answers_to_next} more answers to Level 1`.

```elixir
defmodule RuleMavenWeb.GameLive.OnboardingPanel do
  @moduledoc "Getting Started panel + one-time first-answer card. See player-onboarding spec."
  use RuleMavenWeb, :html

  attr :summary, :map, required: true
  attr :collapsed, :boolean, default: false
  attr :id, :string, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class="onboarding-panel" aria-label="Getting Started">
      <button type="button" class="onboarding-head" phx-click="toggle_getting_started" aria-expanded={to_string(!@collapsed)}>
        <span class="onboarding-title">Getting Started</span>
        <span class="onboarding-count">{@summary.done}/{@summary.total}</span>
        <span class="onboarding-caret" aria-hidden="true">{if @collapsed, do: "›", else: "⌄"}</span>
      </button>

      <ol :if={!@collapsed} class="onboarding-rows">
        <li :for={m <- @summary.milestones} class={["onboarding-row", m.done? && "is-done", m.cta && "is-active"]}>
          <span class="onboarding-row-label">{m.label}</span>
          <span class="onboarding-row-why">{m.why}</span>
          <button :if={m.cta} type="button" class="btn btn-primary btn-sm"
                  phx-click="onboarding_cta" phx-value-kind={m.cta.kind}>
            {m.cta.label}
          </button>
        </li>
      </ol>

      <p :if={!@collapsed and @summary.all_complete?} class="onboarding-footer">
        You're rolling 🎉
        <button type="button" class="btn btn-primary btn-sm" phx-click="onboarding_cta" phx-value-kind="crew">
          Level up your table
        </button>
      </p>
    </section>
    """
  end

  attr :card, :map, default: nil

  def first_answer_card(assigns) do
    ~H"""
    <div :if={@card} class="first-answer-card" role="status">
      <p class="first-answer-title">First question answered ✓ · +{@card.xp_delta} XP</p>
      <p class="first-answer-sub">{@card.answers_to_next} more answers to Level 1</p>
      <button type="button" class="btn btn-ghost btn-sm" phx-click="dismiss_first_answer_card">Got it</button>
    </div>
    """
  end
end
```

Add the `.onboarding-*` / `.first-answer-card` styles alongside the mastery HUD styles (same stylesheet as `mastery_hud`), respecting contrast floors and 390px (collapsed chip is the mobile default — see Task 8/9 wiring).

- [ ] **Step 4: Run tests, verify pass**
Run: `mix test test/rule_maven_web/live/game_live/onboarding_panel_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/onboarding_panel.ex test/rule_maven_web/live/game_live/onboarding_panel_test.exs
git commit -m "feat(onboarding): Getting Started panel + first-answer card components"
```

---

### Task 8: Wire panel into the games index

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/index.ex` (mount ~ line 8-9; sidebar/categories render ~ 828-845)
- Test: covered by an index LiveView smoke assertion (add to the existing index live test file if present; otherwise a minimal new render assertion).

**Interfaces:**
- Consumes: `PlayerOnboarding.summary/1`, `OnboardingPanel.panel/1`.
- Produces: `@onboarding` (summary or nil), `@onboarding_collapsed` assigns; `handle_event("toggle_getting_started")` and `handle_event("onboarding_cta")`.

- [ ] **Step 1: Add mount assigns**
In `mount/3`, after `current_user` is available, compute safely (never crash the page):

```elixir
socket = assign_onboarding(socket)
```

Add a private helper (shared shape with show.ex — but keep one copy per LiveView to respect existing file boundaries; identical body is acceptable here as page chrome):

```elixir
defp assign_onboarding(socket) do
  user = socket.assigns[:current_user]

  summary =
    try do
      user && RuleMaven.PlayerOnboarding.summary(user)
    rescue
      _ -> nil
    end

  collapsed =
    case user && user.tours_seen do
      %{} = seen -> Map.has_key?(seen, "getting_started")
      _ -> false
    end

  assign(socket, onboarding: summary, onboarding_collapsed: collapsed)
end
```

- [ ] **Step 2: Render the panel above categories**
In the sidebar region (around the categories block, index.ex:828-845), add:

```heex
<.live_component :if={false} module={nil} id="noop" /> <!-- placeholder removed; see below -->
```

Actually render the function component directly (no live_component):

```heex
<OnboardingPanel.panel :if={@onboarding} summary={@onboarding} collapsed={@onboarding_collapsed} id="gs-index" />
```

Add `alias RuleMavenWeb.GameLive.OnboardingPanel` to the module.

- [ ] **Step 3: Add event handlers**

```elixir
@impl true
def handle_event("toggle_getting_started", _params, socket) do
  {:noreply, assign(socket, onboarding_collapsed: !socket.assigns.onboarding_collapsed)}
end

def handle_event("onboarding_cta", %{"kind" => kind}, socket) do
  {:noreply, onboarding_cta(socket, kind)}
end
```

```elixir
defp onboarding_cta(socket, "crew"), do: push_navigate(socket, to: ~p"/groups")
defp onboarding_cta(socket, "help"), do: push_navigate(socket, to: ~p"/help")
defp onboarding_cta(socket, "ask") do
  # index has no ask box; nudge into the first Ready game
  case socket.assigns[:games] do
    [game | _] -> push_navigate(socket, to: ~p"/games/#{game}")  # uses existing hashid route
    _ -> socket
  end
end
defp onboarding_cta(socket, _), do: socket
```

(Confirm the exact games route helper + hashid param used elsewhere in index.ex and match it; do not invent a route.)

- [ ] **Step 4: Compile + smoke test**
Run: `mix test test/rule_maven_web/live/game_live/index_test.exs` (or the existing index live test)
Expected: PASS, no warnings. If no index live test exists, add one asserting the panel renders for a fresh user.

- [ ] **Step 5: Verify at 390px**
Manually load `/games` at 390px: collapsed chip default on coarse-pointer, expands on tap, does not shove content. (Hard rule — major UI.)

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/index.ex test/rule_maven_web/live/game_live/index_test.exs
git commit -m "feat(onboarding): Getting Started panel on games index"
```

---

### Task 9: Wire panel + first-answer card into game show

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (mount ~34-39; sidebar `#question-sidebar` ~3482-3527; `handle_info({:mastery_awarded, …})` ~2995)
- Modify: `lib/rule_maven/workers/ask_worker.ex:853-870` (broadcast payload)
- Test: `test/rule_maven_web/live/game_live/...` show live test (extend existing).

**Interfaces:**
- Consumes: `PlayerOnboarding.summary/1`, `OnboardingPanel.panel/1` + `first_answer_card/1`, the `{:mastery_awarded, …}` broadcast.
- Produces: `@onboarding`, `@onboarding_collapsed`, `@first_answer_card` assigns; `handle_event("toggle_getting_started"|"onboarding_cta"|"dismiss_first_answer_card")`. Broadcast payload gains `first_award` + `progress`.

- [ ] **Step 1: Thread `first_award` + `progress` through the broadcast (AskWorker)**
In `maybe_award_mastery/2`, extend the broadcast map:

```elixir
{:mastery_awarded,
 %{
   user_id: updated.user_id,
   game_id: game_id,
   question_log_id: updated.id,
   xp_delta: result.xp_delta,
   xp: result.game_mastery.xp,
   level: result.game_mastery.level,
   level_up: result.level_up,
   unlocked: result.unlocked,
   first_award: result.first_award,
   progress: RuleMaven.Progress.level_progress(result.game_mastery.xp)
 }}
```

- [ ] **Step 2: Show mount assigns**
In `mount/3` after `current_user`/game load, add `socket = assign_onboarding(socket)` and `assign(socket, first_answer_card: nil)`. Reuse the same `assign_onboarding/1` helper body as Task 8 (one copy in show.ex).

- [ ] **Step 3: Render panel + card in the sidebar**
Above categories in `#question-sidebar` (show.ex:3482+):

```heex
<OnboardingPanel.panel :if={@onboarding} summary={@onboarding} collapsed={@onboarding_collapsed} id="gs-show" />
```

Near the answer/HUD region:

```heex
<OnboardingPanel.first_answer_card card={@first_answer_card} />
```

Add `alias RuleMavenWeb.GameLive.OnboardingPanel`.

- [ ] **Step 4: Handle first-answer in the mastery broadcast**
Extend `handle_info({:mastery_awarded, %{user_id: uid} = payload}, socket)` (inside the `user.id == uid` branch, after the existing toast assign):

```elixir
socket =
  if payload[:first_award] && payload[:progress] do
    answers_to_next = ceil(max(payload.progress.span - payload.progress.into, 0) / 15)
    assign(socket, first_answer_card: %{answers_to_next: answers_to_next, xp_delta: payload.xp_delta})
  else
    socket
  end

# refresh the onboarding panel so the milestone ticks live
socket = assign_onboarding(socket)
```

- [ ] **Step 5: Event handlers (toggle / cta / dismiss)**
Place these beside the page's first `handle_event` (sub-bar rule). `ask` CTA scrolls to the ask box via an existing anchor/JS if present, else focuses it — match how the page already focuses the ask input; `crew`/`help` navigate as in Task 8.

```elixir
def handle_event("toggle_getting_started", _p, socket),
  do: {:noreply, assign(socket, onboarding_collapsed: !socket.assigns.onboarding_collapsed)}

def handle_event("dismiss_first_answer_card", _p, socket),
  do: {:noreply, assign(socket, first_answer_card: nil)}

def handle_event("onboarding_cta", %{"kind" => "crew"}, socket),
  do: {:noreply, push_navigate(socket, to: ~p"/groups")}
def handle_event("onboarding_cta", %{"kind" => "help"}, socket),
  do: {:noreply, push_navigate(socket, to: ~p"/help")}
def handle_event("onboarding_cta", %{"kind" => "ask"}, socket),
  do: {:noreply, push_event(socket, "focus_ask", %{})}  # match existing ask-focus mechanism; if none, scroll anchor instead
```

- [ ] **Step 6: Auto-collapse + stamp when complete**
In `assign_onboarding/1` (show + index), when `summary.all_complete?` and not yet stamped, stamp once:

```elixir
if summary && summary.all_complete? && user &&
     not (is_map(user.tours_seen) and Map.has_key?(user.tours_seen, "getting_started")) do
  RuleMaven.Users.mark_tour_seen(user, "getting_started")
end
```

Set `collapsed` true when complete. (`mark_tour_seen/2` is idempotent enough; the guard prevents repeat writes.)

- [ ] **Step 7: Tests**
Run: `mix test test/rule_maven/progress_test.exs test/rule_maven_web/live/game_live/show_test.exs`
Add/extend a show live test: awarding a first answer (simulate the `{:mastery_awarded, first_award: true, progress: …}` message) renders the first-answer card with the right "N more answers" copy; a second award does not.
Expected: PASS, no warnings.

- [ ] **Step 8: Verify at 390px + live**
Load a game show, ask a question (or simulate the broadcast), confirm the card appears once and the panel ticks. 390px: panel collapsed chip, card does not overlap the answer. (Hard rule.)

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex lib/rule_maven/workers/ask_worker.ex test/rule_maven_web/live/game_live/show_test.exs
git commit -m "feat(onboarding): panel + first-answer card on game show"
```

---

### Task 10: /help note (help + tours upkeep)

**Files:**
- Modify: `lib/rule_maven_web/controllers/page_html/help.html.heex`

- [ ] **Step 1: Add a short "Getting Started & rewards" section**
Add a brief block explaining: the Getting Started checklist, earning XP/levels by asking, daily streaks, badges, and inviting your crew. Match the page's existing section markup + heading style. Include an anchor the `:help` CTA can target (e.g. `id="rewards"`).

- [ ] **Step 2: Compile check**
Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven_web/controllers/page_html/help.html.heex
git commit -m "docs(help): explain Getting Started, XP, streaks, and rewards"
```

---

### Task 11: Final verification

- [ ] **Step 1: Run all touched test files (tee to log)**
Run: `mix test test/rule_maven/users_test.exs test/rule_maven/progress_test.exs test/rule_maven/player_onboarding_test.exs test/rule_maven_web/live/game_live/onboarding_panel_test.exs test/rule_maven_web/live/game_live/show_test.exs 2>&1 | tee tmp/onboarding-test.log`
Expected: all PASS, zero warnings.

- [ ] **Step 2: Full-file compile with warnings-as-errors**
Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Contrast + 390px sweep**
Run the contrast test file if the panel added colors; manually verify `/games` and a game show at 390px.

- [ ] **Step 4: Clean up the temp log**

```bash
rm -f tmp/onboarding-test.log
```

---

## Self-Review

**Spec coverage:**
- Aha (existing tour) — untouched, milestone `:first_question` ticks off it → Task 6/9. ✓
- A progression primary — `:level_1` + first-answer card → Tasks 4/5/6/7/9. ✓
- Streak (B) — migration + bump + milestone → Tasks 1/2/3/6. ✓
- Crew (C) — `:crew` milestone + CTA → Tasks 6/8/9. ✓
- Badge/standing (D) — `:badge` milestone → Task 6. ✓
- Panel on index + show, collapse, auto-collapse+stamp, mobile chip → Tasks 7/8/9. ✓
- First-answer card once-ever via count==1 → Tasks 5/9. ✓
- Never blocks play (rescue-wrapped summary) → Task 8/9 `assign_onboarding`. ✓
- /help note → Task 10. ✓
- 1 migration, no backfill → Task 1. ✓

**Placeholder scan:** one intentional "match the existing ask-focus mechanism" / "match the games route helper" note — these are *verify-against-existing-code* instructions, not TBDs; the implementer confirms the exact helper name before use. All code blocks are complete. The stray `<.live_component :if={false}…>` placeholder in Task 8 Step 2 is explicitly replaced in the same step by the real `OnboardingPanel.panel` line.

**Type consistency:** `award/5` result `:first_award` (Task 5) consumed in AskWorker broadcast (Task 9) and card copy. `summary/1` map keys (`milestones/done/total/all_complete?/current_streak`) consistent across Tasks 6/7/8/9. `Milestone` fields (`key/label/why/done?/cta`) consistent. `cta.kind` values (`:ask/:crew/:help`) match the `onboarding_cta` handlers (string `"ask"/"crew"/"help"` — note: `phx-value-kind` serializes the atom to string; handlers match on strings ✓).

**Open confirmations for the implementer (verify against code, do not invent):**
1. Exact games route/hashid helper in `index.ex` for the `ask` CTA nudge.
2. The ask-input focus mechanism on `show.ex` (JS hook/event vs anchor) for `focus_ask`.
3. `user_fixture/0` and `game_fixture/0` availability in the test support (they're used widely; confirm import).
