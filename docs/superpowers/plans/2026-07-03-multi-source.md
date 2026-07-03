# Multi-Source Games Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed rulebook sources with a fixed authority order, source-scoped citations, retrieval dedup, and many-to-many expansion↔base links.

**Architecture:** Two phases. Phase 1 (Tasks 1–4) replaces the single `games.parent_game_id` FK with a `game_expansion_links` join table so an expansion can belong to several base games/editions. Phase 2 (Tasks 5–9) adds `documents.kind` (8-value enum, fixed authority order), threads source metadata through retrieval → prompt → answer JSON → citation validation → display, and dedups near-duplicate chunks at retrieval time.

**Tech Stack:** Elixir/Phoenix, Ecto + pgvector, Oban, SweetXml (BGG XML), Prompts registry (`RuleMaven.Prompts`).

**Spec:** `docs/superpowers/specs/2026-07-03-multi-source-design.md`

## Global Constraints

- Authority order (high→low), everywhere it appears: `errata, faq, rulebook, scenario, howto, reference, notes, other`.
- Every LLM prompt text lives in the Prompts registry (`lib/rule_maven/prompts.ex` defaults + `app_settings` overrides) — never hardcoded in calling code.
- Users never see file paths/PDFs — citations show source *labels* only.
- Never expose raw ids in URLs (existing Hashid rule) — no new URLs in this plan.
- Test output: tee full-suite runs to `./tmp/<name>.log`; delete the log when done.
- Commit after every task (established repo rule).

---

## Phase 1 — Many-to-many expansion links

### Task 1: `game_expansion_links` table, schema, and link helpers

**Files:**
- Create: `priv/repo/migrations/<ts>_create_game_expansion_links.exs`
- Create: `lib/rule_maven/games/expansion_link.ex`
- Modify: `lib/rule_maven/games.ex` (new helpers near `expansions_for/1`, ~line 140)
- Test: `test/rule_maven/games_expansion_links_test.exs` (new)

**Interfaces:**
- Produces: `Games.link_expansion(expansion_id, base_game_id) :: :ok` (idempotent),
  `Games.unlink_expansion(expansion_id, base_game_id) :: :ok`,
  `Games.base_ids_for(game_id) :: [integer]`,
  `Games.expansion?(game_id) :: boolean`.
- Table: `game_expansion_links(expansion_id, base_game_id)`, unique pair, both FK → games `on_delete: :delete_all`. `parent_game_id` is NOT dropped yet (Task 4).

- [ ] **Step 1: Write failing tests**

```elixir
defmodule RuleMaven.GamesExpansionLinksTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games

  defp game(name) do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  test "link_expansion is idempotent and supports multiple bases" do
    exp = game("Promo")
    base1 = game("Ed1")
    base2 = game("Ed2")

    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base2.id)

    assert Enum.sort(Games.base_ids_for(exp.id)) == Enum.sort([base1.id, base2.id])
    assert Games.expansion?(exp.id)
    refute Games.expansion?(base1.id)
  end

  test "unlink_expansion removes one pair only" do
    exp = game("Promo")
    base1 = game("Ed1")
    base2 = game("Ed2")
    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base2.id)

    :ok = Games.unlink_expansion(exp.id, base1.id)

    assert Games.base_ids_for(exp.id) == [base2.id]
  end

  test "deleting a base game cascades its links but not the expansion" do
    exp = game("Promo")
    base = game("Ed1")
    :ok = Games.link_expansion(exp.id, base.id)

    {:ok, _} = Games.delete_game(base)

    assert Games.base_ids_for(exp.id) == []
    assert Games.get_game(exp.id)
  end

  test "migration backfilled existing parent_game_id rows" do
    exp = game("Legacy")
    base = game("Base")
    {:ok, exp} = Games.update_game(exp, %{parent_game_id: base.id})
    # Simulate what the backfill does for pre-existing rows.
    :ok = Games.link_expansion(exp.id, base.id)
    assert Games.base_ids_for(exp.id) == [base.id]
  end
end
```

- [ ] **Step 2: Run tests, verify failure**

Run: `mix test test/rule_maven/games_expansion_links_test.exs`
Expected: FAIL — `Games.link_expansion/2 is undefined`.

- [ ] **Step 3: Migration**

`mix ecto.gen.migration create_game_expansion_links`, body:

```elixir
def up do
  create table(:game_expansion_links) do
    add :expansion_id, references(:games, on_delete: :delete_all), null: false
    add :base_game_id, references(:games, on_delete: :delete_all), null: false
    timestamps(type: :utc_datetime)
  end

  create unique_index(:game_expansion_links, [:expansion_id, :base_game_id])
  create index(:game_expansion_links, [:base_game_id])

  # Backfill from the legacy single-parent FK (column dropped in a later migration).
  execute """
  INSERT INTO game_expansion_links (expansion_id, base_game_id, inserted_at, updated_at)
  SELECT id, parent_game_id, NOW(), NOW() FROM games WHERE parent_game_id IS NOT NULL
  """
end

def down do
  drop table(:game_expansion_links)
end
```

- [ ] **Step 4: Schema**

`lib/rule_maven/games/expansion_link.ex`:

```elixir
defmodule RuleMaven.Games.ExpansionLink do
  @moduledoc """
  Join row linking an expansion game to ONE base game it works with. An
  expansion supported by several editions has one row per base (replaces the
  old single `games.parent_game_id` FK).
  """
  use Ecto.Schema

  schema "game_expansion_links" do
    belongs_to :expansion, RuleMaven.Games.Game, foreign_key: :expansion_id
    belongs_to :base_game, RuleMaven.Games.Game, foreign_key: :base_game_id
    timestamps(type: :utc_datetime)
  end
end
```

- [ ] **Step 5: Helpers in `games.ex`** (alias `RuleMaven.Games.ExpansionLink` at top)

```elixir
@doc "Link an expansion to a base game. Idempotent (unique pair, conflict ignored)."
def link_expansion(expansion_id, base_game_id) do
  now = DateTime.utc_now(:second)

  Repo.insert_all(
    ExpansionLink,
    [%{expansion_id: expansion_id, base_game_id: base_game_id, inserted_at: now, updated_at: now}],
    on_conflict: :nothing,
    conflict_target: [:expansion_id, :base_game_id]
  )

  :ok
end

def unlink_expansion(expansion_id, base_game_id) do
  Repo.delete_all(
    from l in ExpansionLink,
      where: l.expansion_id == ^expansion_id and l.base_game_id == ^base_game_id
  )

  :ok
end

@doc "Ids of every base game this expansion is linked to."
def base_ids_for(game_id) do
  Repo.all(from l in ExpansionLink, where: l.expansion_id == ^game_id, select: l.base_game_id)
end

@doc "True when the game is linked as an expansion of at least one base."
def expansion?(game_id) do
  Repo.exists?(from l in ExpansionLink, where: l.expansion_id == ^game_id)
end
```

- [ ] **Step 6: Migrate + run tests**

Run: `mix ecto.migrate && mix test test/rule_maven/games_expansion_links_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit** — `feat: game_expansion_links join table + link helpers`

---

### Task 2: Rewrite expansion queries onto the join table

**Files:**
- Modify: `lib/rule_maven/games.ex:70-214` (`list_games_with_documents`, `list_playable_games`, `list_games_needing_bgg`, `list_requested_games`, `list_base_games`, `expansions_for/1`, `expansion_counts/1`, `expansion_pull_counts/1`, `expansion_with_doc_counts/1`, `expansions_with_documents/1`, `base_game_for/1`)
- Test: `test/rule_maven/games_expansion_links_test.exs` (extend)

**Interfaces:**
- Consumes: `ExpansionLink`, `link_expansion/2` from Task 1.
- Produces: same public function names/returns as today, plus new
  `Games.base_games_for(game) :: [%Game{}]` (name-sorted). `base_game_for/1`
  kept, now returns the first of `base_games_for/1` or nil.
- "Base game" predicate everywhere becomes *not linked as an expansion*:
  `where: g.id not in subquery(from l in ExpansionLink, select: l.expansion_id)`.

- [ ] **Step 1: Write failing tests** (append to `games_expansion_links_test.exs`)

```elixir
  describe "join-backed queries" do
    setup do
      exp = game("Promo")
      base1 = game("Ed1")
      base2 = game("Ed2")
      :ok = Games.link_expansion(exp.id, base1.id)
      :ok = Games.link_expansion(exp.id, base2.id)
      %{exp: exp, base1: base1, base2: base2}
    end

    test "expansions_for lists the expansion under every linked base", ctx do
      assert Enum.map(Games.expansions_for(ctx.base1), & &1.id) == [ctx.exp.id]
      assert Enum.map(Games.expansions_for(ctx.base2), & &1.id) == [ctx.exp.id]
    end

    test "expansion_counts counts per base", ctx do
      counts = Games.expansion_counts([ctx.base1.id, ctx.base2.id])
      assert counts[ctx.base1.id] == 1
      assert counts[ctx.base2.id] == 1
    end

    test "expansions_with_documents needs a published doc", ctx do
      assert Games.expansions_with_documents(ctx.base1) == []

      {:ok, doc} =
        Games.create_document(%{game_id: ctx.exp.id, label: "Promo rules", full_text: "some promo rules text"})

      {:ok, _} = Games.update_document(doc, %{status: "published"})
      assert Enum.map(Games.expansions_with_documents(ctx.base1), & &1.id) == [ctx.exp.id]
    end

    test "base_games_for returns all bases; base_game_for the first", ctx do
      assert Games.base_games_for(ctx.exp) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([ctx.base1.id, ctx.base2.id])

      assert Games.base_game_for(ctx.exp).id in [ctx.base1.id, ctx.base2.id]
      assert Games.base_game_for(ctx.base1) == nil
    end

    test "list_base_games excludes linked expansions", ctx do
      ids = Games.list_base_games() |> Enum.map(& &1.id)
      assert ctx.base1.id in ids
      refute ctx.exp.id in ids
    end
  end
```

- [ ] **Step 2: Run, verify failure**

Run: `mix test test/rule_maven/games_expansion_links_test.exs`
Expected: FAIL — old queries read `parent_game_id` (nil for join-only links); `base_games_for/1` undefined.

- [ ] **Step 3: Rewrite queries**

Add a private helper and swap every usage:

```elixir
# "Is a base game" filter: not linked as an expansion of anything.
defp not_expansion(query) do
  where(query, [g], g.id not in subquery(from l in ExpansionLink, select: l.expansion_id))
end
```

Replace each `where: is_nil(g.parent_game_id)` in `list_games_with_documents` (line 77), `list_playable_games` (97), `list_games_needing_bgg` (112), `list_requested_games` (129), `list_base_games` (136) with a pipe through `not_expansion/1` (convert those queries to pipe syntax where needed).

```elixir
def expansions_for(%Game{} = game) do
  Repo.all(
    from g in Game,
      join: l in ExpansionLink,
      on: l.expansion_id == g.id,
      where: l.base_game_id == ^game.id,
      select: g
  )
  |> Enum.sort_by(&String.downcase(&1.name))
end

def expansion_counts(game_ids) do
  Repo.all(
    from l in ExpansionLink,
      where: l.base_game_id in ^game_ids,
      group_by: l.base_game_id,
      select: {l.base_game_id, count(l.expansion_id)}
  )
  |> Map.new()
end

def expansion_pull_counts(game_ids) do
  Repo.all(
    from l in ExpansionLink,
      join: g in Game,
      on: g.id == l.expansion_id,
      where: l.base_game_id in ^game_ids,
      where: not is_nil(g.bgg_id) and is_nil(g.bgg_data),
      group_by: l.base_game_id,
      select: {l.base_game_id, count(l.expansion_id)}
  )
  |> Map.new()
end

def expansion_with_doc_counts(game_ids) do
  Repo.all(
    from l in ExpansionLink,
      join: d in Document,
      on: d.game_id == l.expansion_id and d.status == "published",
      where: l.base_game_id in ^game_ids,
      group_by: l.base_game_id,
      select: {l.base_game_id, count(l.expansion_id, :distinct)}
  )
  |> Map.new()
end

def expansions_with_documents(%Game{} = base_game) do
  Repo.all(
    from g in Game,
      join: l in ExpansionLink,
      on: l.expansion_id == g.id,
      join: d in Document,
      on: d.game_id == g.id,
      where: l.base_game_id == ^base_game.id and d.status == "published",
      distinct: true,
      select: g
  )
  |> Enum.sort_by(&String.downcase(&1.name))
end

@doc "All base games this expansion is linked to, name-sorted ([] for base games)."
def base_games_for(%Game{} = game) do
  Repo.all(
    from g in Game,
      join: l in ExpansionLink,
      on: l.base_game_id == g.id,
      where: l.expansion_id == ^game.id,
      select: g
  )
  |> Enum.sort_by(&String.downcase(&1.name))
end

@doc "First linked base game (legacy single-parent shape), nil for base games."
def base_game_for(%Game{} = game), do: game |> base_games_for() |> List.first()
```

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/games_expansion_links_test.exs`
Expected: PASS. Then `mix test 2>&1 | tee tmp/task2.log | tail -5` — fix any caller assuming old shapes (callers keep the same return types, so expect green; `parent_game_id` writes still work because the column still exists).

- [ ] **Step 5: Commit** — `feat: expansion queries read game_expansion_links`

---

### Task 3: BGG linking writes the join table (multi-parent)

**Files:**
- Modify: `lib/rule_maven/bgg.ex:320-353` (`link_expansions/2`)
- Modify: `lib/rule_maven_web/live/game_live/form.ex:850` (unlink handler), `:322-325` and `:1635` (`parent_game_id` reads)
- Test: `test/rule_maven/bgg_link_expansions_test.exs` (new; check for an existing bgg test file first and extend it instead if present)

**Interfaces:**
- Consumes: `Games.link_expansion/2`, `Games.unlink_expansion/2`, `Games.expansion?/1`, `Games.base_games_for/1` (Tasks 1–2).
- Produces: `BGG.link_expansions/2` same signature, now links *every* matched inbound parent (no single-parent guard) and every matched outbound expansion. No `parent_game_id` writes remain anywhere.

- [ ] **Step 1: Write failing test**

```elixir
defmodule RuleMaven.BGGLinkExpansionsTest do
  use RuleMaven.DataCase
  alias RuleMaven.{BGG, Games}

  defp game(name, bgg_id) do
    {:ok, g} =
      Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}", bgg_id: bgg_id})
    g
  end

  test "inbound links attach the expansion to every matched base" do
    exp = game("Promo", 111)
    ed1 = game("Ed1", 222)
    ed2 = game("Ed2", 333)

    :ok =
      BGG.link_expansions(exp, [
        %{id: 222, value: "Ed1", inbound: "true"},
        %{id: 333, value: "Ed2", inbound: "true"},
        %{id: 999, value: "Not imported", inbound: "true"}
      ])

    assert Enum.sort(Games.base_ids_for(exp.id)) == Enum.sort([ed1.id, ed2.id])
  end

  test "outbound links attach matched expansions to this base" do
    base = game("Base", 444)
    exp = game("Exp", 555)

    :ok = BGG.link_expansions(base, [%{id: 555, value: "Exp", inbound: "false"}])

    assert Games.base_ids_for(exp.id) == [base.id]
  end

  test "re-linking is idempotent" do
    exp = game("Promo", 666)
    base = game("Base", 777)
    links = [%{id: 777, value: "Base", inbound: "true"}]

    :ok = BGG.link_expansions(exp, links)
    :ok = BGG.link_expansions(exp, links)

    assert Games.base_ids_for(exp.id) == [base.id]
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `mix test test/rule_maven/bgg_link_expansions_test.exs`
Expected: FAIL — old code sets `parent_game_id` (single) and skips the second base.

- [ ] **Step 3: Rewrite `link_expansions/2`**

```elixir
@doc """
After enriching a game, link its expansions via `game_expansion_links`.
inbound="true": this game is an expansion of the linked game — link to EVERY
matched base (an expansion can be supported by several editions).
inbound="false": the linked game is an expansion of this game.
Unmatched bgg_ids are ignored (linked when that edition is imported and
enriched/relinked). Idempotent.
"""
def link_expansions(game, expansion_links) do
  {inbound, outbound} = Enum.split_with(expansion_links, &(&1.inbound == "true"))

  for link <- inbound,
      base = RuleMaven.Repo.get_by(RuleMaven.Games.Game, bgg_id: link.id),
      base != nil do
    RuleMaven.Games.link_expansion(game.id, base.id)
  end

  for link <- outbound,
      expansion = RuleMaven.Repo.get_by(RuleMaven.Games.Game, bgg_id: link.id),
      expansion != nil do
    RuleMaven.Games.link_expansion(expansion.id, game.id)
  end

  :ok
end
```

- [ ] **Step 4: Update `form.ex` call sites**

Read each site before editing (semantics, not just syntax):
- `:850` unlink handler: `Games.update_game(exp, %{parent_game_id: nil})` → `Games.unlink_expansion(exp.id, game.id)` where `game` is the base whose editor page we're on.
- `:322-325`: `if game.parent_game_id` / `parent_selected_id: game.parent_game_id` → `bases = Games.base_games_for(game)`; keep the existing single-select UI working with `parent_selected_id: List.first(bases) && List.first(bases).id`, and render additional linked bases read-only (label list) if the editor shows the parent picker.
- `:1635`: `is_nil(game.parent_game_id)` → `not Games.expansion?(game.id)`.
- Also `lib/rule_maven/games.ex:211 base_game_for` callers are already handled (Task 2 kept the name).

- [ ] **Step 5: Run tests**

Run: `mix test test/rule_maven/bgg_link_expansions_test.exs && mix test 2>&1 | tee tmp/task3.log | tail -5`
Expected: PASS / suite green.

- [ ] **Step 6: Commit** — `feat: BGG expansion linking is many-to-many`

---

### Task 4: Drop `parent_game_id`

**Files:**
- Create: `priv/repo/migrations/<ts>_drop_parent_game_id.exs`
- Modify: `lib/rule_maven/games/game.ex:33-34,56` (remove assoc + cast)
- Test: full suite

- [ ] **Step 1: Remove remaining references**

Run: `grep -rn "parent_game_id\|parent_game\b\|:expansions" lib/ test/ --include="*.ex" --include="*.exs"` and eliminate every remaining code reference (schema `belongs_to :parent_game`, `has_many :expansions`, changeset cast at `game.ex:56`, any test fixtures using `parent_game_id` — rewrite fixtures to `Games.link_expansion/2`). Migrations stay untouched.

- [ ] **Step 2: Migration**

```elixir
def up do
  alter table(:games), do: remove(:parent_game_id)
end

def down do
  alter table(:games) do
    add :parent_game_id, references(:games, on_delete: :nilify_all)
  end
end
```

- [ ] **Step 3: Migrate + full suite**

Run: `mix ecto.migrate && mix test 2>&1 | tee tmp/task4.log | tail -5`
Expected: green (minus any pre-existing failures noted in the log — `prepare_render_test.exs:30` fails on master as of 2026-07-03).

- [ ] **Step 4: Commit** — `feat: drop games.parent_game_id (join table is authoritative)`

---

## Phase 2 — Typed sources

### Task 5: `Document.kind` replaces `is_core`

**Files:**
- Create: `priv/repo/migrations/<ts>_add_kind_to_documents.exs`
- Modify: `lib/rule_maven/games/document.ex` (field + changeset validation; remove `is_core` field at line ~92)
- Modify: `lib/rule_maven_web/live/game_live/form.ex:355,373-386,1214,1238,2002,3192-3199` (is_core toggle → kind select)
- Test: `test/rule_maven/games_document_kind_test.exs` (new)

**Interfaces:**
- Produces: `documents.kind` string, default `"rulebook"`, validated inclusion in
  `~w(errata faq rulebook scenario howto reference notes other)`.
  `RuleMaven.Games.Document.kinds/0` returns that list (order = authority, high→low).
  `RuleMaven.Games.Document.authority(kind) :: 0..7` (index in list).
  `RuleMaven.Games.Document.kind_label(kind)` → UI label ("Errata / corrections", "FAQ / rulings", "Rulebook", "Scenario / campaign book", "How to play / quickstart", "Reference / player aid", "Designer notes", "Other").

- [ ] **Step 1: Write failing tests**

```elixir
defmodule RuleMaven.GamesDocumentKindTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games
  alias RuleMaven.Games.Document

  defp doc(attrs) do
    {:ok, game} = Games.create_game(%{name: "Kind #{System.unique_integer([:positive])}"})
    Games.create_document(Map.merge(%{game_id: game.id, label: "Rules", full_text: "text"}, attrs))
  end

  test "defaults to rulebook" do
    {:ok, d} = doc(%{})
    assert d.kind == "rulebook"
  end

  test "accepts every declared kind, rejects garbage" do
    for k <- Document.kinds() do
      assert {:ok, %{kind: ^k}} = doc(%{kind: k})
    end

    assert {:error, changeset} = doc(%{kind: "manifesto"})
    assert %{kind: ["is invalid"]} = errors_on(changeset)
  end

  test "authority order is fixed high-to-low" do
    assert Document.kinds() == ~w(errata faq rulebook scenario howto reference notes other)
    assert Document.authority("errata") < Document.authority("rulebook")
    assert Document.authority("rulebook") < Document.authority("howto")
  end
end
```

- [ ] **Step 2: Run, verify failure** — `mix test test/rule_maven/games_document_kind_test.exs` → FAIL (`kind` unknown).

- [ ] **Step 3: Migration**

```elixir
def up do
  alter table(:documents) do
    add :kind, :string, null: false, default: "rulebook"
    remove :is_core
  end
end

def down do
  alter table(:documents) do
    remove :kind
    add :is_core, :boolean, default: false
  end
end
```

- [ ] **Step 4: Schema + helpers** (in `Document`, replacing `field :is_core`)

```elixir
@kinds ~w(errata faq rulebook scenario howto reference notes other)
@kind_labels %{
  "errata" => "Errata / corrections",
  "faq" => "FAQ / rulings",
  "rulebook" => "Rulebook",
  "scenario" => "Scenario / campaign book",
  "howto" => "How to play / quickstart",
  "reference" => "Reference / player aid",
  "notes" => "Designer notes",
  "other" => "Other"
}

field :kind, :string, default: "rulebook"

@doc "All kinds, authority order high→low."
def kinds, do: @kinds
@doc "Authority rank: 0 (errata, highest) … 7 (other)."
def authority(kind), do: Enum.find_index(@kinds, &(&1 == kind)) || length(@kinds)
def kind_label(kind), do: Map.get(@kind_labels, kind, kind)
```

Changeset: cast `:kind`, `validate_inclusion(:kind, @kinds)`, remove `:is_core` from cast.

- [ ] **Step 5: UI swap in `form.ex`**

Replace the is_core checkbox (lines 3192-3199 render, 355/373-386 events, 1214/1238/2002 state) with a `<select>` of `Document.kinds()` rendered via `kind_label/1`, defaulting `"rulebook"`, wired to the existing `Games.update_document(doc, %{kind: kind})` update path (same event plumbing the toggle used — rename event to `"set_kind"`). Show the kind label as a badge on each source row.

- [ ] **Step 6: Migrate + tests**

Run: `mix ecto.migrate && mix test test/rule_maven/games_document_kind_test.exs && mix test 2>&1 | tee tmp/task5.log | tail -5`
Expected: kind tests PASS; fix any `is_core` fallout the grep in Step 5 missed (`grep -rn is_core lib/ test/`).

- [ ] **Step 7: Commit** — `feat: documents.kind typed sources (replaces is_core)`

---

### Task 6: Retrieval returns source metadata + dedups near-duplicates

**Files:**
- Modify: `lib/rule_maven/games.ex:2666-2713` (`retrieve_chunks_for_games/3`) and its two internal fallbacks' return shapes
- Modify: `lib/rule_maven/llm.ex:139-140,175` (consume new shape)
- Test: `test/rule_maven/games_retrieval_test.exs` (extend if exists, else create)

**Interfaces:**
- Consumes: `Document.authority/1` (Task 5).
- Produces: `retrieve_chunks_for_games(game_ids, question, opts)` now returns a list of maps:
  `%{content: String.t(), document_id: integer, label: String.t(), kind: String.t(), game_id: integer, game_name: String.t()}`.
  New opt `:base_game_id` (defaults to `hd(game_ids)`) — used for the dedup tiebreak.
  Fallback paths (full-text, keyword) return the same map shape with the document's own metadata.
- Dedup: over-fetch `limit * 2` with embeddings selected; greedy pass keeps a chunk unless cosine similarity ≥ 0.97 with an already-kept chunk; on collision, keep the lower `{authority(kind), game_id == base ? 0 : 1}` tuple; trim to `limit`.

- [ ] **Step 1: Write failing tests**

Test seam: build two docs with near-identical chunk content and hand-set equal embeddings (insert `Chunk` rows directly with `Pgvector.new/1` vectors), then call with `embedding:` opt so no API call happens.

```elixir
defmodule RuleMaven.GamesRetrievalTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk

  defp published_doc(game, label, kind) do
    {:ok, d} =
      Games.create_document(%{game_id: game.id, label: label, kind: kind, full_text: "seed"})
    {:ok, d} = Games.update_document(d, %{status: "published"})
    d
  end

  defp put_chunk(doc, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  test "returns source metadata with each chunk" do
    {:ok, game} = Games.create_game(%{name: "Meta #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Core rules", "rulebook")
    put_chunk(doc, "[Page 1]\ndraw five cards", List.duplicate(0.1, 1536))

    [chunk] = Games.retrieve_chunks_for_games([game.id], "cards", embedding: List.duplicate(0.1, 1536))

    assert %{content: "[Page 1]\ndraw five cards", label: "Core rules", kind: "rulebook",
             game_id: game_id, game_name: _, document_id: _} = chunk
    assert game_id == game.id
  end

  test "near-duplicate chunks collapse to the higher-authority source" do
    {:ok, game} = Games.create_game(%{name: "Dedup #{System.unique_integer([:positive])}"})
    rulebook = published_doc(game, "Rulebook", "rulebook")
    guide = published_doc(game, "Learn to play", "howto")
    vec = List.duplicate(0.1, 1536)
    put_chunk(rulebook, "[Page 3]\nscoring: majority wins", vec)
    put_chunk(guide, "[Page 1]\nscoring: majority wins!", vec)

    chunks = Games.retrieve_chunks_for_games([game.id], "scoring", embedding: vec, limit: 6)

    assert Enum.count(chunks, &(&1.content =~ "majority wins")) == 1
    assert Enum.find(chunks, &(&1.content =~ "majority wins")).kind == "rulebook"
  end

  test "same kind: base game beats expansion on a duplicate" do
    {:ok, base} = Games.create_game(%{name: "Base #{System.unique_integer([:positive])}"})
    {:ok, exp} = Games.create_game(%{name: "Exp #{System.unique_integer([:positive])}"})
    :ok = Games.link_expansion(exp.id, base.id)
    vec = List.duplicate(0.1, 1536)
    put_chunk(published_doc(base, "Base rules", "rulebook"), "[Page 2]\nsetup: shuffle deck", vec)
    put_chunk(published_doc(exp, "Exp rules", "rulebook"), "[Page 2]\nsetup: shuffle deck.", vec)

    chunks =
      Games.retrieve_chunks_for_games([base.id, exp.id], "setup",
        embedding: vec, base_game_id: base.id, limit: 6)

    kept = Enum.filter(chunks, &(&1.content =~ "shuffle deck"))
    assert [%{game_id: kept_game}] = kept
    assert kept_game == base.id
  end
end
```

(Adjust vector dimension to the project's embedding size — check `priv/repo/migrations/*rulebook_chunks*` for the `vector(N)` declaration before writing the test.)

- [ ] **Step 2: Run, verify failure** — old return shape is `{nil, text}` tuples → pattern-match failures.

- [ ] **Step 3: Implement**

In `retrieve_chunks_for_games/3`:

```elixir
def retrieve_chunks_for_games(game_ids, question, opts \\ []) when is_list(game_ids) do
  limit = Keyword.get(opts, :limit, 6)
  base_game_id = Keyword.get(opts, :base_game_id, List.first(game_ids))

  embed_result =
    case Keyword.get(opts, :embedding) do
      nil -> RuleMaven.Embed.embed(question)
      vec -> {:ok, vec}
    end

  case embed_result do
    {:ok, question_vec} ->
      chunks =
        Repo.all(
          from c in Chunk,
            join: d in Document,
            on: c.document_id == d.id,
            join: g in Game,
            on: g.id == d.game_id,
            where:
              d.game_id in ^game_ids and d.status == "published" and
                not is_nil(c.embedding),
            order_by:
              fragment("cosine_distance(?, ?::vector)", c.embedding, ^Pgvector.new(question_vec)),
            # Over-fetch so dedup can drop near-duplicates and still fill the limit.
            limit: ^(limit * 2),
            select: %{
              id: c.id,
              content: c.content,
              section_label: c.section_label,
              references_section: c.references_section,
              embedding: c.embedding,
              document_id: d.id,
              label: d.label,
              kind: d.kind,
              game_id: d.game_id,
              game_name: g.name
            }
        )

      if chunks == [] do
        published_full_text_fallback(game_ids)
      else
        chunks
        |> dedup_near_duplicates(base_game_id)
        |> Enum.take(limit)
        |> pull_referenced_chunks(game_ids)
        |> Enum.map(&Map.drop(&1, [:embedding]))
      end

    {:error, _} ->
      keyword_retrieve_multi(game_ids, question, limit)
  end
end

# Greedy near-duplicate collapse. Chunks arrive relevance-ordered; each is kept
# unless it's ≥ @dup_threshold cosine-similar to an already-kept chunk, in which
# case the more authoritative of the two survives (kind authority, then base
# game beats expansion). Guides restating the rulebook and expansions
# reprinting base rules stop crowding the retrieval budget.
@dup_threshold 0.97

defp dedup_near_duplicates(chunks, base_game_id) do
  Enum.reduce(chunks, [], fn chunk, kept ->
    case Enum.split_with(kept, &(cosine_sim(&1.embedding, chunk.embedding) >= @dup_threshold)) do
      {[], _} -> kept ++ [chunk]
      {[dup | _], rest} -> rest ++ [pick_authoritative(dup, chunk, base_game_id)]
    end
  end)
end

defp pick_authoritative(a, b, base_game_id) do
  Enum.min_by([a, b], fn c ->
    {RuleMaven.Games.Document.authority(c.kind), if(c.game_id == base_game_id, do: 0, else: 1)}
  end)
end

defp cosine_sim(a, b) do
  a = Pgvector.to_list(a)
  b = Pgvector.to_list(b)
  dot = Enum.zip_with(a, b, &*/2) |> Enum.sum()
  na = :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1))))
  nb = :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))
  if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
end
```

Update `published_full_text_fallback/1`, `keyword_retrieve_multi/3`, and `pull_referenced_chunks/2` to carry/emit the same map shape (each already joins or can join `Document`; add `label`, `kind`, `game_id`, `game_name`, `document_id`). Read each before editing.

Update the two consumers of the old `{nil, text}` shape in `lib/rule_maven/llm.ex`:
- line 140: `context = Enum.map_join(chunks, "\n\n---\n\n", & &1.content)` (replaced properly in Task 7)
- line 175: `source_chunks: Enum.map(chunks, & &1.content)`
- `retrieve_chunks/3` (games.ex:2657) keeps delegating — callers of *it* (check with grep) get maps now; update them.

- [ ] **Step 4: Run tests** — retrieval tests PASS, then `mix test 2>&1 | tee tmp/task6.log | tail -5`.

- [ ] **Step 5: Commit** — `feat: retrieval carries source metadata + near-duplicate dedup`

---

### Task 7: Grouped prompt context + authority rules + `source` in answer JSON

**Files:**
- Modify: `lib/rule_maven/llm.ex:136-181` (`call_llm/7` context assembly), `:829` (`build_system_prompt/4`), `decode_answer/1` (~line 880)
- Modify: `lib/rule_maven/prompts.ex:20` region (`@answer` default template)
- Test: `test/rule_maven/llm_context_grouping_test.exs` (new), extend `test/rule_maven/llm_test.exs` answer-parsing cases

**Interfaces:**
- Consumes: chunk maps from Task 6.
- Produces: `LLM.build_context_block(chunks, base_game_id) :: String.t()` (public, unit-testable) emitting per-source groups:

```
=== BASE GAME "Ethnos" — RULEBOOK "Core rules" ===
[Page 5] chunk text

=== EXPANSION "Ethnos: X" — ERRATA "X errata" ===
[Page 2] chunk text
```

- Answer JSON gains optional `"source"` (the source label string) → `llm_result[:cited_source]`.
- `@answer` template gains an `AUTHORITY` section (edited in `prompts.ex` default; registry override mechanism untouched).

- [ ] **Step 1: Write failing tests**

```elixir
defmodule RuleMaven.LLMContextGroupingTest do
  use ExUnit.Case, async: true
  alias RuleMaven.LLM

  @chunks [
    %{content: "[Page 5] majority wins", document_id: 1, label: "Core rules",
      kind: "rulebook", game_id: 10, game_name: "Ethnos"},
    %{content: "[Page 2] fairies score double", document_id: 2, label: "X errata",
      kind: "errata", game_id: 20, game_name: "Ethnos: X"}
  ]

  test "groups chunks under base/expansion source headers" do
    block = LLM.build_context_block(@chunks, 10)

    assert block =~ ~s(=== BASE GAME "Ethnos" — RULEBOOK "Core rules" ===)
    assert block =~ ~s(=== EXPANSION "Ethnos: X" — ERRATA "X errata" ===)
    # Chunk text sits under its own header.
    assert block =~ "[Page 5] majority wins"
  end

  test "single-source games get one header, no expansion label" do
    block = LLM.build_context_block([hd(@chunks)], 10)
    assert block =~ "BASE GAME"
    refute block =~ "EXPANSION"
  end
end
```

And in `llm_test.exs` (answer parsing), add:

```elixir
test "decode_answer maps the source field" do
  json = ~s({"answer":"x","citation":"y","page":3,"source":"X errata","verdict":"clear"})
  assert {:ok, result} = RuleMaven.LLM.decode_answer(json)
  assert result[:cited_source] == "X errata"
  assert result[:cited_page] == 3
end
```

(If `decode_answer/1` is private, test through the existing seam `llm_test.exs` already uses for citation parsing — read that file first and mirror its approach.)

- [ ] **Step 2: Run, verify failure** — `build_context_block/2` undefined.

- [ ] **Step 3: Implement `build_context_block/2`**

```elixir
@doc """
Groups retrieval chunks into per-source blocks for the answer prompt. Chunks
stay in relevance order within a group; groups are ordered by kind authority
then base-before-expansion, so the most authoritative material leads.
"""
def build_context_block(chunks, base_game_id) do
  chunks
  |> Enum.group_by(&{&1.game_id, &1.document_id})
  |> Enum.map(fn {_key, [first | _] = group} -> {first, group} end)
  |> Enum.sort_by(fn {first, _} ->
    {RuleMaven.Games.Document.authority(first.kind),
     if(first.game_id == base_game_id, do: 0, else: 1)}
  end)
  |> Enum.map_join("\n\n", fn {first, group} ->
    scope =
      if first.game_id == base_game_id,
        do: ~s(BASE GAME "#{first.game_name}"),
        else: ~s(EXPANSION "#{first.game_name}")

    header = ~s(=== #{scope} — #{String.upcase(first.kind)} "#{first.label}" ===)
    header <> "\n" <> Enum.map_join(group, "\n\n", & &1.content)
  end)
end
```

In `call_llm/7` replace line 140:

```elixir
context = build_context_block(chunks, game.id)
```

- [ ] **Step 4: Template + decode**

In `prompts.ex` `@answer` default, add (inside the instructions section, before the JSON schema):

```
AUTHORITY: sources are grouped under headers. When sources conflict, follow
this order (highest wins): ERRATA > FAQ > RULEBOOK > SCENARIO > HOWTO >
REFERENCE > NOTES > OTHER. An EXPANSION source overrides a BASE GAME source
of the same type for content involving that expansion. If you relied on a
higher-authority source over a contradicting lower one, say so briefly
(e.g. "The rulebook says X, but the FAQ clarifies Y").
```

Extend the JSON schema description in the same template: `"source": the exact source name from the header you cited (e.g. "Core rules"), alongside the existing "page".

In `decode_answer/1`, map `"source"` → `:cited_source` exactly as `"page"` → `:cited_page` is mapped, and add `cited_source: llm_result[:cited_source]` to the `call_llm` result map (llm.ex:156-176).

- [ ] **Step 5: Run tests** — both new files PASS; `mix test 2>&1 | tee tmp/task7.log | tail -5`.

- [ ] **Step 6: Commit** — `feat: grouped ask context with authority rules + cited source`

---

### Task 8: Persist `cited_source`, source-scoped citation validation

**Files:**
- Create: `priv/repo/migrations/<ts>_add_cited_source_to_questions_log.exs`
- Modify: `lib/rule_maven/games/question_log.ex` (field + changeset, near `cited_page` line 13)
- Modify: `lib/rule_maven/games/citations.ex` (`valid?` gains source scope)
- Modify: `lib/rule_maven/workers/ask_worker.ex:195` (pass source + per-source chunks)
- Modify: `lib/rule_maven/llm.ex:175` (`source_chunks` becomes `[{label, content}]`)
- Test: extend `test/rule_maven/citations_test.exs`

**Interfaces:**
- Consumes: `cited_source` from Task 7's answer decode; chunk maps from Task 6.
- Produces: `questions_log.cited_source` (string, nullable).
  `Citations.valid?(passage, cited_page, source_chunks, cited_source \\ nil)` where
  `source_chunks :: [%{label: String.t(), content: String.t()}]`. With a
  `cited_source` that matches a label (case-insensitive), page+passage validate
  against that source's chunks only; nil or unmatched label falls back to the
  pooled behavior (all chunks).

- [ ] **Step 1: Write failing tests** (append to `citations_test.exs`; mirror its existing fixture style — read it first)

```elixir
  describe "source-scoped validation" do
    @rulebook %{label: "Core rules", content: "[Page 5]\nThe player with the most banners wins the region."}
    @faq %{label: "Official FAQ", content: "[Page 2]\nTies award the region to no one."}

    test "cited page must exist in the cited source" do
      # Page 5 exists in Core rules, not in the FAQ.
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Core rules")
      refute Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Official FAQ")
    end

    test "unknown source label falls back to pooled validation" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Nonexistent")
    end

    test "nil source keeps legacy pooled behavior" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], nil)
    end
  end
```

- [ ] **Step 2: Run, verify failure** — `valid?/4` undefined (arity).

- [ ] **Step 3: Implement**

Migration:

```elixir
def change do
  alter table(:questions_log) do
    add :cited_source, :string
  end
end
```

`question_log.ex`: `field :cited_source, :string` + add to the changeset cast list (line 62 region).

`citations.ex`: add the 4-arity head; normalize `source_chunks` to maps
(`%{label: l, content: c}`; keep accepting plain strings by wrapping them as
`%{label: nil, content: s}` so old callers/tests pass), scope to
`Enum.filter(chunks, &(String.downcase(&1.label || "") == String.downcase(cited_source)))`
when the filter is non-empty, else use all chunks; then run the existing
passage/page logic over the scoped set. `valid?/3` delegates to `valid?/4` with `nil`.

`llm.ex:175`: `source_chunks: Enum.map(chunks, &%{label: &1.label, content: &1.content})`.

`ask_worker.ex:195`: pass `llm_result[:cited_source]` as the 4th arg and persist
`cited_source` on the QuestionLog row alongside `cited_page` (find the existing
insert/update attrs map in the same function).

- [ ] **Step 4: Run** — `mix test test/rule_maven/citations_test.exs test/rule_maven/workers/ask_worker_test.exs`, then full suite tee'd to `tmp/task8.log`.

- [ ] **Step 5: Commit** — `feat: source-scoped citation validation + cited_source persistence`

---

### Task 9: Citation display shows the source

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex:2130-2134` (figcaption) and the message-map assembly in the same file that populates `msg[:cited_page]` (grep `cited_page` in show.ex; add `cited_source` wherever `cited_page` is put on the msg map, both live-answer and history-load paths)
- Test: `test/rule_maven_web/` — extend whichever LiveView test asserts on `"Rulebook · p."` (find with `grep -rn "p\.\|cited" test/rule_maven_web/ | grep -i show`); if none exists, add a render-component-level assertion in the existing show LiveView test file.

**Interfaces:**
- Consumes: `cited_source` on QuestionLog rows / ask results (Task 8).
- Produces: figcaption text `{source label} · p.{page}`; falls back to `"Rulebook"` when `cited_source` is nil (all pre-existing answers). For a source belonging to an expansion (the row's game differs from the page's game), prefix the expansion name: `{expansion name}: {label} · p.{page}` — derive by comparing the cited source's document `game_id` (available when loading answers; if not cheaply available on the msg map, fall back to the label alone — labels for expansion docs typically carry the expansion name already; decide at implementation against the actual msg assembly code).

- [ ] **Step 1: Failing test** asserting the new figcaption for a message with `cited_source: "Official FAQ"`, `cited_page: 2` renders `Official FAQ · p.2`, and nil `cited_source` renders `Rulebook · p.{n}` (exact test file/helper mirrors the existing show tests — read them first).

- [ ] **Step 2: Implement**

`show.ex:2133`:

```heex
{msg[:cited_source] || "Rulebook"} &middot; p.{msg.cited_page}
```

plus `cited_source` threading in the msg-map assembly sites.

- [ ] **Step 3: Run** — targeted LiveView test file, then full suite tee'd to `tmp/task9.log`; delete all `tmp/task*.log` files when green.

- [ ] **Step 4: Commit** — `feat: answer citations name their source`

---

## Self-review notes (already applied)

- Spec §7 (expansion links) → Tasks 1–4; §1 (kind) → Task 5; §5 (dedup) → Task 6; §2–3 (conflict/prompt) → Task 7; §4 (citations) → Tasks 8–9; §6 (prep UX) → Task 5 Step 5.
- Single-source regression guard: Task 7 test "single-source games get one header"; Citations 3-arity kept delegating (Task 8).
- Known pre-existing failure: `test/rule_maven_web/prepare_render_test.exs:30` fails on master (2026-07-03) — not a regression signal.
- Embedding vector dimension in Task 6 tests must be checked against the chunks migration before writing the test.
