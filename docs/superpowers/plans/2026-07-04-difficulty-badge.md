# Difficulty Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a BGG-sourced complexity badge (Light/Medium/Heavy) on the game show page, computed at render time from a stored `weight` float, with zero LLM/worker cost per request.

**Architecture:** Parse BGG's `averageweight` XML field during the existing enrich flow, store it as `games.weight`, bucket it with a pure render helper (same pattern as `answer_confidence/1`), and render a badge in the show-page header. A one-time Mix task backfills `weight` for already-imported games by reparsing their cached raw XML (`bgg_data`) — no new BGG API calls.

**Tech Stack:** Elixir/Phoenix, Ecto migrations, SweetXml (BGG XML parsing), Oban (existing enrich worker, untouched logic — only a tracked-field addition), ExUnit.

## Global Constraints

- `weight` is nullable (`float`, no default) — BGG has no rating for new/unranked games.
- No fallback when `weight` is nil: badge is hidden entirely (matches the "Did you know?" card's no-fallback precedent — see [[fun-features]] memory).
- Expansion aggregation: badge = **max** weight across base game + currently-selected expansions.
- No new LLM calls, no new Oban queue — badge is a pure render helper; backfill is a Mix task, not a worker (matches existing `mix rule_maven.backfill_embeddings` precedent, since batch backfill has no existing Oban template in this codebase).
- Follow existing xpath/changeset/test conventions exactly (shown in each task below) — do not introduce a new XML library or test style.

---

### Task 1: Migration — add `weight` column to `games`

**Files:**
- Create: `priv/repo/migrations/20260704150000_add_weight_to_games.exs`

**Interfaces:**
- Produces: `games.weight` column (`float`, nullable), consumed by Task 2 (schema) and Task 6 (backfill).

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddWeightToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :weight, :float
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `== Running ... AddWeightToGames.change/0 forward` followed by success, no errors.

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/20260704150000_add_weight_to_games.exs
git commit -m "feat(games): add weight column for BGG complexity rating"
```

---

### Task 2: Game schema — add `weight` field

**Files:**
- Modify: `lib/rule_maven/games/game.ex`
- Test: `test/rule_maven/games_test.exs`

**Interfaces:**
- Consumes: `games.weight` column from Task 1.
- Produces: `%RuleMaven.Games.Game{weight: float() | nil}`, castable via `Game.changeset/2` on key `:weight`. Consumed by Task 3 (BGG parser output), Task 7 (badge render).

- [ ] **Step 1: Write the failing test**

Add to the `describe "games"` block in `test/rule_maven/games_test.exs` (alongside the existing `create_game/1 with valid data creates a game` test):

```elixir
test "create_game/1 persists weight" do
  valid_attrs = %{name: "some name", bgg_id: 42, weight: 2.6667}

  assert {:ok, %Game{} = game} = Games.create_game(valid_attrs)
  assert_in_delta game.weight, 2.6667, 0.0001
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_test.exs -k "persists weight"`
Expected: FAIL — `game.weight` is nil or `KeyError`/cast ignored, since the field doesn't exist on the schema yet.

- [ ] **Step 3: Add the field and cast entry**

In `lib/rule_maven/games/game.ex`, add the field after `field :playing_time, :integer`:

```elixir
    field :playing_time, :integer
    field :weight, :float
```

And add `:weight` to the `cast/3` list, right after `:playing_time`:

```elixir
    |> cast(attrs, [
      :name,
      :bgg_id,
      :bgg_rank,
      :year_published,
      :min_players,
      :max_players,
      :playing_time,
      :weight,
      :image_url,
      :bgg_data,
      :category,
      :theme_palette
    ])
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/games_test.exs -k "persists weight"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games/game.ex test/rule_maven/games_test.exs
git commit -m "feat(games): cast weight through Game changeset"
```

---

### Task 3: BGG parser — extract `averageweight` from XML

**Files:**
- Modify: `lib/rule_maven/bgg.ex`
- Test: Create `test/rule_maven/bgg_test.exs`

**Interfaces:**
- Consumes: raw BGG item XML (string).
- Produces: `RuleMaven.BGG.extract_weight/1`, a public function `(xml_string_or_parsed :: any()) -> float() | nil`, used both by `parse_game_info/1` internally (Step 3) and by the backfill Mix task (Task 6). Also: `parse_game_info/1`'s returned map now includes `weight: float() | nil`, which flows into `Games.update_game/2` (Task 2's cast) exactly like `year_published` etc. already do.

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven/bgg_test.exs`:

```elixir
defmodule RuleMaven.BGGTest do
  use ExUnit.Case, async: true

  alias RuleMaven.BGG

  @sample_xml """
  <items>
    <item type="boardgame" id="123">
      <yearpublished value="2020" />
      <minplayers value="2" />
      <maxplayers value="4" />
      <playingtime value="60" />
      <image>https://example.com/img.jpg</image>
      <thumbnail>https://example.com/thumb.jpg</thumbnail>
      <statistics>
        <ratings>
          <averageweight value="2.6667" />
        </ratings>
      </statistics>
    </item>
  </items>
  """

  test "extract_weight/1 parses averageweight from raw XML" do
    assert_in_delta BGG.extract_weight(@sample_xml), 2.6667, 0.0001
  end

  test "extract_weight/1 returns nil when averageweight is missing or zero" do
    xml_without_weight = """
    <items>
      <item type="boardgame" id="123">
        <yearpublished value="2020" />
      </item>
    </items>
    """

    assert BGG.extract_weight(xml_without_weight) == nil
  end

  test "extract_weight/1 returns nil for averageweight of 0.0 (BGG's unrated sentinel)" do
    xml_zero_weight = """
    <items>
      <item type="boardgame" id="123">
        <statistics>
          <ratings>
            <averageweight value="0" />
          </ratings>
        </statistics>
      </item>
    </items>
    """

    assert BGG.extract_weight(xml_zero_weight) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/bgg_test.exs`
Expected: FAIL — `BGG.extract_weight/1` undefined function.

- [ ] **Step 3: Implement `extract_weight/1` and wire it into `parse_game_info/1`**

In `lib/rule_maven/bgg.ex`, add near the other private parse helpers (`parse_int/1`):

```elixir
  @doc """
  Extracts BGG's community `averageweight` (1.0-5.0 complexity rating) from raw
  item XML. Public so the one-time backfill Mix task can reparse cached
  `bgg_data` without re-fetching from the BGG API. Returns nil when missing or
  when BGG reports 0.0 (its sentinel for "not enough ratings yet").
  """
  def extract_weight(xml) do
    xml
    |> parse()
    |> xpath(
      ~x"//items/item"e,
      average_weight: ~x"./statistics/ratings/averageweight/@value"s |> transform_by(&parse_float/1)
    )
    |> Map.get(:average_weight)
    |> case do
      nil -> nil
      0.0 -> nil
      w -> w
    end
  end

  defp parse_float(""), do: nil
  defp parse_float(nil), do: nil
  defp parse_float(str), do: elem(Float.parse(str), 0)
```

Then update `parse_game_info/1` to call it and include `weight` in the returned map:

```elixir
  defp parse_game_info(xml) do
    parsed =
      xml
      |> parse()
      |> xpath(
        ~x"//items/item"e,
        year_published: ~x"./yearpublished/@value"s |> transform_by(&parse_int/1),
        min_players: ~x"./minplayers/@value"s |> transform_by(&parse_int/1),
        max_players: ~x"./maxplayers/@value"s |> transform_by(&parse_int/1),
        playing_time: ~x"./playingtime/@value"s |> transform_by(&parse_int/1),
        image_url: ~x"./image/text()"s,
        thumbnail_url: ~x"./thumbnail/text()"s,
        links: [
          ~x"./link[@type='boardgameexpansion']"l,
          id: ~x"./@id"s |> transform_by(&parse_int/1),
          value: ~x"./@value"s,
          inbound: ~x"./@inbound"s
        ]
      )

    {:ok,
     %{
       year_published: parsed.year_published,
       min_players: parsed.min_players,
       max_players: parsed.max_players,
       playing_time: parsed.playing_time,
       image_url: parsed.image_url,
       weight: extract_weight(xml),
       expansion_links: parsed.links
     }}
  end
```

Note: `extract_weight/1` re-parses the XML from scratch (calls `parse()` again) rather than reusing the already-parsed document from `parse_game_info/1`'s xpath call, because it must also work standalone from a raw XML string in the backfill task (Task 6), where no other parse pass has happened. This is a one-time-per-game parse, not a hot path — the duplication is cheap and keeps `extract_weight/1` usable in isolation.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/bgg_test.exs`
Expected: PASS, all 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/bgg.ex test/rule_maven/bgg_test.exs
git commit -m "feat(bgg): parse averageweight into game weight"
```

---

### Task 4: BggEnrichWorker — track `weight` changes in job summary

**Files:**
- Modify: `lib/rule_maven/workers/bgg_enrich_worker.ex`

**Interfaces:**
- Consumes: `Game.weight` field from Task 2, populated via Task 3's enrich flow.
- Produces: no new interface — purely improves the existing job-log summary line so admins can see when a weight changed.

- [ ] **Step 1: Add `:weight` to `@tracked_fields`**

In `lib/rule_maven/workers/bgg_enrich_worker.ex`, change:

```elixir
  @tracked_fields ~w(image_url year_published min_players max_players playing_time bgg_rank category)a
```

to:

```elixir
  @tracked_fields ~w(image_url year_published min_players max_players playing_time bgg_rank category weight)a
```

- [ ] **Step 2: Verify existing worker tests still pass**

Run: `mix test test/rule_maven/workers/bgg_enrich_worker_test.exs` (if this file doesn't exist, run `mix test --only bgg` or `mix test test/rule_maven/workers/`)
Expected: all existing tests PASS (no new test needed — this is a one-line addition to an existing tracked list, exercised indirectly by any enrich-flow test already in place).

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven/workers/bgg_enrich_worker.ex
git commit -m "feat(bgg): report weight changes in enrich job summary"
```

---

### Task 5: Difficulty bucketing helper

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex`

**Interfaces:**
- Consumes: `float() | nil` weight.
- Produces: `difficulty_bucket/1`, a private function `(weight :: float() | nil) -> {label :: String.t(), color :: String.t()} | nil`, consumed by Task 7's badge render.

- [ ] **Step 1: Write the failing test**

Since `difficulty_bucket/1` is private to `show.ex`, test it via a small public wrapper is not idiomatic here — instead, follow this codebase's existing pattern where such pure helpers are exercised indirectly through LiveView render tests, OR (preferred, simpler, matches TDD) temporarily make it a `def` (not `defp`) so it's directly testable, matching how other pure render helpers in this file are tested. Check first:

Run: `grep -n "answer_confidence\|conf_word" test/rule_maven_web/live/game_live/show_test.exs`

If no direct unit tests exist for `answer_confidence/1` either (i.e. it's only exercised via full LiveView render), skip a standalone unit test and instead write the render-level test in Task 7 Step 1, which exercises `difficulty_bucket/1` transitively. Note this decision in the Task 7 commit message context — do not write a placeholder test here.

- [ ] **Step 2: Implement `difficulty_bucket/1`**

In `lib/rule_maven_web/live/game_live/show.ex`, add near `answer_confidence/1`:

```elixir
  # ── Difficulty badge ──
  # Pure bucketing of BGG's community averageweight (1.0-5.0 scale) into a
  # label. nil weight (unrated / not yet backfilled) means no badge — no
  # fallback text, matching the "Did you know?" card's precedent.
  defp difficulty_bucket(nil), do: nil

  defp difficulty_bucket(weight) do
    cond do
      weight < 1.5 -> {"Light", "var(--green)"}
      weight < 2.5 -> {"Medium-Light", "var(--blue)"}
      weight < 3.5 -> {"Medium", "var(--yellow)"}
      weight < 4.5 -> {"Medium-Heavy", "var(--orange, var(--yellow))"}
      true -> {"Heavy", "var(--red)"}
    end
  end
```

- [ ] **Step 3: Confirm compilation**

Run: `mix compile --warnings-as-errors`
Expected: no warnings (unused-function warnings would appear if not yet called — this is fine transiently since Task 7 wires up the call site next; if the plan is executed strictly in order within the same session before Task 7, this step may show an "unused function" warning, which is expected and resolved by Task 7).

- [ ] **Step 4: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat(ui): add difficulty bucketing helper"
```

---

### Task 6: Backfill Mix task

**Files:**
- Create: `lib/mix/tasks/backfill_weight.ex`
- Test: Create `test/mix/tasks/backfill_weight_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.BGG.extract_weight/1` (Task 3), `RuleMaven.Games.update_game/2` (existing), `games.bgg_data` (existing cached raw XML column) and `games.weight` (Task 1/2).
- Produces: `mix rule_maven.backfill_weight` — no new runtime interface, ops-only command.

- [ ] **Step 1: Write the failing test**

Create `test/mix/tasks/backfill_weight_test.exs`:

```elixir
defmodule Mix.Tasks.RuleMaven.BackfillWeightTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games

  @sample_xml """
  <items>
    <item type="boardgame" id="1">
      <statistics>
        <ratings>
          <averageweight value="3.14" />
        </ratings>
      </statistics>
    </item>
  </items>
  """

  test "backfills weight from cached bgg_data, skipping already-set rows" do
    {:ok, needs_backfill} =
      Games.create_game(%{name: "Needs Backfill", bgg_id: 1, bgg_data: @sample_xml})

    {:ok, already_set} =
      Games.create_game(%{
        name: "Already Set",
        bgg_id: 2,
        bgg_data: @sample_xml,
        weight: 1.0
      })

    {:ok, no_cache} = Games.create_game(%{name: "No Cache", bgg_id: 3})

    Mix.Tasks.RuleMaven.BackfillWeight.run([])

    assert_in_delta Games.get_game!(needs_backfill.id).weight, 3.14, 0.001
    assert Games.get_game!(already_set.id).weight == 1.0
    assert Games.get_game!(no_cache.id).weight == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/backfill_weight_test.exs`
Expected: FAIL — `Mix.Tasks.RuleMaven.BackfillWeight` module undefined.

- [ ] **Step 3: Implement the Mix task**

Create `lib/mix/tasks/backfill_weight.ex`, following the exact structure of `lib/mix/tasks/backfill_embeddings.ex`:

```elixir
defmodule Mix.Tasks.RuleMaven.BackfillWeight do
  @shortdoc "Backfill BGG complexity weight for existing games from cached XML"
  @moduledoc """
  Reparses each game's already-cached BGG XML (`bgg_data`) to extract the
  `averageweight` complexity rating, without calling the BGG API again.
  Skips games that already have `weight` set or have no cached XML.

      mix rule_maven.backfill_weight
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Repo, Games, BGG}
  alias RuleMaven.Games.Game

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    games =
      Repo.all(
        from g in Game,
          where: is_nil(g.weight) and not is_nil(g.bgg_data)
      )

    if games == [] do
      Mix.shell().info("No games need weight backfill.")
    else
      Mix.shell().info("Backfilling weight for #{length(games)} games...")

      Enum.each(games, fn game ->
        case BGG.extract_weight(game.bgg_data) do
          nil ->
            :ok

          weight ->
            {:ok, _} = Games.update_game(game, %{weight: weight})
            Mix.shell().info("  #{game.name}: weight=#{weight}")
        end
      end)

      Mix.shell().info("Done.")
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/backfill_weight_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/backfill_weight.ex test/mix/tasks/backfill_weight_test.exs
git commit -m "feat(bgg): add one-time weight backfill mix task"
```

---

### Task 7: Render the badge on the game show page

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex`
- Test: `test/rule_maven_web/live/game_live/show_test.exs` (add a case; if this file doesn't exist, check `test/rule_maven_web/live/game_live/` for the correct existing LiveView test file covering the show page and extend that one instead)

**Interfaces:**
- Consumes: `@game` (`%Game{weight: ...}`, existing assign), `@expansions` (existing assign, list of expansion `%Game{}` structs), `@included_expansions` (existing assign, `%{expansion_id => boolean}` map) — all already present in `show.ex` per current assigns (lines 19/206, 171, 39/214).
- Produces: a `difficulty_weight/2`-computed value rendered as a pill badge in the header; no new assign needed since it's computed inline at render time from existing assigns (cheap, no DB hit).

- [ ] **Step 1: Write the failing test**

Find the exact existing LiveView test module first:

Run: `ls test/rule_maven_web/live/game_live/`

Add a test to the show-page test file (adjust module/path if the grep above shows a different filename than assumed):

```elixir
test "renders difficulty badge when game has a weight", %{conn: conn} do
  game = game_fixture(%{weight: 3.2})
  {:ok, _view, html} = live(conn, ~p"/games/#{game}")

  assert html =~ "Medium"
end

test "hides difficulty badge when game has no weight", %{conn: conn} do
  game = game_fixture(%{weight: nil})
  {:ok, _view, html} = live(conn, ~p"/games/#{game}")

  refute html =~ "Medium"
  refute html =~ "Light"
  refute html =~ "Heavy"
end
```

(Adjust setup boilerplate — conn, published-game requirements, auth — to match whatever the existing tests in that file already do to reach a renderable show page; copy the setup block from a neighboring passing test rather than inventing new setup.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live/show_test.exs -k "difficulty badge"`
Expected: FAIL — badge markup not present yet.

- [ ] **Step 3: Add a `difficulty_weight/2` helper and wire the render**

Add this helper near `difficulty_bucket/1` (Task 5):

```elixir
  # Max weight across the base game and currently-selected expansions —
  # expansions only add complexity, never reduce it.
  defp difficulty_weight(game, expansions_and_selection)

  defp difficulty_weight(game, {expansions, included}) do
    selected_ids = included |> Enum.filter(fn {_id, on?} -> on? end) |> Enum.map(&elem(&1, 0))

    selected_weights =
      expansions
      |> Enum.filter(&(&1.id in selected_ids))
      |> Enum.map(& &1.weight)
      |> Enum.reject(&is_nil/1)

    [game.weight | selected_weights]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      weights -> Enum.max(weights)
    end
  end
```

In the header block (around line 1610-1626), inside the first `<div class="flex items-center gap-1" ...>`, right after the `<h1>` and before/after the "View on BGG" link:

```heex
      <h1 class="text-sm font-bold truncate" style="max-width:300px">{@game.name}</h1>
      <% difficulty = difficulty_bucket(difficulty_weight(@game, {@expansions, @included_expansions})) %>
      <%= if difficulty do %>
        <% {label, color} = difficulty %>
        <span
          class="pill-link"
          style={"color:#{color};border-color:#{color}"}
        >{label}</span>
      <% end %>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/game_live/show_test.exs -k "difficulty badge"`
Expected: PASS, both tests green.

- [ ] **Step 5: Run full show_test.exs suite to check for regressions**

Run: `mix test test/rule_maven_web/live/game_live/show_test.exs`
Expected: all PASS, no regressions from the header markup change.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/show_test.exs
git commit -m "feat(ui): render difficulty badge with max-of-expansions aggregation"
```

---

### Task 8: Full regression pass and manual verification

**Files:** none (verification-only task)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: all tests PASS, no regressions across the whole app.

- [ ] **Step 2: Run the backfill task against dev data (optional local sanity check)**

Run: `mix rule_maven.backfill_weight`
Expected: reports either "No games need weight backfill." (if dev DB has no `bgg_data`-cached games without weight) or a per-game weight list with no errors.

- [ ] **Step 3: Manually verify in the browser**

Start the app (`mix phx.server` or the project's existing dev-run flow), open a published game's show page that has BGG data, and confirm the badge renders with a sensible label next to the title. Toggle an expansion with a higher weight than the base game (if test data allows) and confirm the badge updates to the higher tier.

- [ ] **Step 4: Commit any fixups**

If manual verification surfaces a rendering issue (e.g. CSS/spacing), fix inline and commit:

```bash
git add -A
git commit -m "fix(ui): difficulty badge rendering fixups"
```

(Skip this step entirely if no fixups are needed.)
