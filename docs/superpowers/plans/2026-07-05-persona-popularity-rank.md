# Persona Popularity Rank + 10-Persona Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise per-game generated persona voices from a 6-max cap to a 10-max cap, and have the LLM additionally rank each persona by predicted popularity among that game's fans, storing and using that rank to order the voice picker.

**Architecture:** Extend the existing `generate_voices` prompt/JSON contract with a `popularity_rank` field, thread it through `LLM.parse_voices/1` (sort + cap), persist it on `game_voices.popularity_rank` via `RuleMaven.Voices.GameVoice`/`replace_generated/2`, and use it as the primary `ORDER BY` in `Voices.game_voice_defs/1`.

**Tech Stack:** Elixir, Phoenix, Ecto/Postgres, ExUnit.

## Global Constraints

- Prompts live in the `RuleMaven.Prompts` registry, never hardcoded elsewhere (per project convention).
- "Fewer if theme is thin; do not pad" — the LLM must never be forced to invent 10 personas for a thin rulebook.
- Rank changes alone must NOT invalidate cached restyles (`answer_voices`) — only `style` or `label` changes do that (existing rule in `replace_generated/2`).
- Global (`@voices`) personas are hand-authored, unranked, and always shown first, in their fixed order, before generated ones. This plan does not touch them.
- Plan/tier gating on rank is explicitly out of scope for this plan.

---

### Task 1: Prompt contract — raise cap to 10, add `popularity_rank`

**Files:**
- Modify: `lib/rule_maven/prompts.ex` (the `@generate_voices` module attribute, used at `key: "generate_voices"`, currently around lines 480–529)

**Interfaces:**
- Produces: no code interface — this is prompt text consumed later by `LLM.generate_voices/2` (Task 2) and parsed by `LLM.parse_voices/1` (Task 3). The JSON shape the LLM is asked to return now includes `"popularity_rank"` as a top-level integer field per persona object.

- [ ] **Step 1: Edit the `@generate_voices` prompt text**

In `lib/rule_maven/prompts.ex`, find:

```elixir
  Return between 3 and 6 voices - fewer if the theme is thin; do not pad.
```

Replace with:

```elixir
  Return between 3 and 10 voices - fewer if the theme is thin; do not pad.
```

Find the JSON shape block:

```elixir
  [
    {
      "slug": "kebab-case-stable-id",
      "label": "Short Display Name",
      "emoji": "🙂",
      "style": "a one-sentence description of how this persona talks, in the same form as 'a swashbuckling pirate who uses nautical slang.'",
      "description": "a short user-facing blurb (max ~12 words) saying who this persona is, e.g. 'The ship's weary quartermaster, buried in paperwork.'",
      "loading_phrases": ["Hoisting the sails…", "Counting the doubloons…", "Sighing at landlubbers…", "Polishing the anchor…"]
    }
  ]
```

Replace with (adds `popularity_rank`):

```elixir
  [
    {
      "slug": "kebab-case-stable-id",
      "label": "Short Display Name",
      "emoji": "🙂",
      "style": "a one-sentence description of how this persona talks, in the same form as 'a swashbuckling pirate who uses nautical slang.'",
      "description": "a short user-facing blurb (max ~12 words) saying who this persona is, e.g. 'The ship's weary quartermaster, buried in paperwork.'",
      "loading_phrases": ["Hoisting the sails…", "Counting the doubloons…", "Sighing at landlubbers…", "Polishing the anchor…"],
      "popularity_rank": 1
    }
  ]
```

Find the "Rules:" bullet list in the same prompt and add a new bullet after the `loading_phrases` bullet (before the "Make them distinct..." bullet):

```elixir
  - "popularity_rank" is an integer, 1 = the persona fans of THIS specific
    game would most want to use, ascending with no gaps, unique across the
    personas you return (1, 2, 3, ...). Judge this by fit and fun for fans of
    this game specifically - not generic persona appeal.
```

- [ ] **Step 2: Update the registry description for `generate_voices`**

Find:

```elixir
    %{
      key: "generate_voices",
      group: "Persona",
      label: "Per-game personas — prompt",
      description: "Invents 3–6 personas themed to a specific game from its rulebook.",
      vars: ~w(game_name rulebook),
      default: @generate_voices
    },
```

Replace `description` with:

```elixir
      description: "Invents 3–10 personas themed to a specific game from its rulebook, ranked by predicted popularity.",
```

- [ ] **Step 3: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean, no warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/rule_maven/prompts.ex
git commit -m "feat: raise persona cap to 10 and add popularity_rank to prompt"
```

---

### Task 2: `LLM.generate_voices/2` — raise `max_tokens`

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`generate_voices/2`, around line 1671–1695)

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change to `generate_voices/2` (`(game_name :: String.t(), rulebook_text :: String.t()) :: {:ok, [map()]} | {:error, term()}`).

- [ ] **Step 1: Edit `max_tokens`**

Find in `lib/rule_maven/llm.ex`:

```elixir
    case chat(prompt, "generate_voices",
           system: RuleMaven.Prompts.template("generate_voices_system"),
           # Each voice now carries 20+ loading_phrases and a picker description
           # on top of its style, so a full 6-voice set needs a lot more room.
           # Too low and the JSON truncates mid-array → parse fails → no voices.
           max_tokens: 8000
         ) do
```

Replace with:

```elixir
    case chat(prompt, "generate_voices",
           system: RuleMaven.Prompts.template("generate_voices_system"),
           # Each voice now carries 20+ loading_phrases, a picker description,
           # and a popularity_rank on top of its style, so a full 10-voice set
           # needs a lot more room. Too low and the JSON truncates mid-array →
           # parse fails → no voices.
           max_tokens: 13000
         ) do
```

- [ ] **Step 2: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add lib/rule_maven/llm.ex
git commit -m "feat: raise generate_voices max_tokens for 10-persona responses"
```

---

### Task 3: `LLM.parse_voices/1` / `coerce_voice/1` — extract rank, sort, cap at 10

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`parse_voices/1` and `coerce_voice/1`, around lines 1700–1747)
- Test: `test/rule_maven/llm_test.exs`

**Interfaces:**
- Consumes: raw LLM JSON text (list of objects each optionally containing `"popularity_rank"`).
- Produces: `parse_voices/1 :: (text :: String.t()) :: [%{slug: String.t(), label: String.t(), emoji: String.t(), style: String.t(), description: String.t() | nil, loading_phrases: [String.t()], popularity_rank: integer()}]`, sorted ascending by `popularity_rank`, capped at 10 entries. This is the list `RuleMaven.Voices.replace_generated/2` (Task 5) consumes — each map must include `popularity_rank` as a plain integer (never nil) since Task 5 passes it straight into `Ecto.Changeset.cast/3` on an integer field.

- [ ] **Step 1: Write failing tests**

Add to `test/rule_maven/llm_test.exs`, inside the existing `describe "voice parsing includes loading_phrases"` block (or a new describe block right after it — add this new block after that describe's closing `end`, around line 543):

```elixir
  describe "voice parsing: popularity_rank" do
    test "parses popularity_rank when present" do
      json =
        ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald","popularity_rank":3}])

      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.popularity_rank == 3
    end

    test "defaults popularity_rank to a large sentinel when missing" do
      json = ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald"}])
      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.popularity_rank == 999_999
    end

    test "defaults popularity_rank to a large sentinel when non-integer" do
      json =
        ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald","popularity_rank":"first"}])

      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.popularity_rank == 999_999
    end

    test "sorts results by popularity_rank ascending regardless of input order" do
      json = ~s([
        {"slug":"c","label":"C","emoji":"🙂","style":"x","popularity_rank":3},
        {"slug":"a","label":"A","emoji":"🙂","style":"x","popularity_rank":1},
        {"slug":"b","label":"B","emoji":"🙂","style":"x","popularity_rank":2}
      ])

      slugs = RuleMaven.LLM.__parse_voices__(json) |> Enum.map(& &1.slug)
      assert slugs == ["a", "b", "c"]
    end

    test "caps at 10 voices, keeping the 10 lowest (best) ranks" do
      entries =
        for i <- 1..12 do
          ~s({"slug":"v#{i}","label":"V#{i}","emoji":"🙂","style":"x","popularity_rank":#{i}})
        end

      json = "[" <> Enum.join(entries, ",") <> "]"
      result = RuleMaven.LLM.__parse_voices__(json)

      assert length(result) == 10
      assert Enum.map(result, & &1.slug) == for(i <- 1..10, do: "v#{i}")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs --only line:526` — actually run the whole file since line numbers shift; use: `mix test test/rule_maven/llm_test.exs`
Expected: the 5 new tests FAIL (function clause / `KeyError` on `:popularity_rank`, or cap-at-6 mismatch on the 12-entry test). Existing tests in the file still pass.

- [ ] **Step 3: Implement `coerce_voice/1` change**

In `lib/rule_maven/llm.ex`, find:

```elixir
  defp coerce_voice(%{"label" => label, "emoji" => emoji, "style" => style} = m)
       when is_binary(label) and is_binary(emoji) and is_binary(style) do
    label = String.trim(label)
    style = String.trim(style)
    slug = m |> Map.get("slug", label) |> to_string() |> slugify()
    loading = m |> Map.get("loading_phrases", []) |> coerce_phrases()

    description =
      case Map.get(m, "description") do
        d when is_binary(d) -> d |> String.trim() |> String.slice(0, 120)
        _ -> nil
      end

    if label != "" and style != "" and slug != "" do
      %{
        slug: slug,
        label: label,
        emoji: String.trim(emoji),
        style: style,
        description: if(description == "", do: nil, else: description),
        loading_phrases: loading
      }
    end
  end

  defp coerce_voice(_), do: nil
```

Replace with:

```elixir
  # Sorts last when the LLM omits or garbles the field, rather than crashing
  # or silently defaulting to "most popular".
  @popularity_rank_fallback 999_999

  defp coerce_voice(%{"label" => label, "emoji" => emoji, "style" => style} = m)
       when is_binary(label) and is_binary(emoji) and is_binary(style) do
    label = String.trim(label)
    style = String.trim(style)
    slug = m |> Map.get("slug", label) |> to_string() |> slugify()
    loading = m |> Map.get("loading_phrases", []) |> coerce_phrases()

    description =
      case Map.get(m, "description") do
        d when is_binary(d) -> d |> String.trim() |> String.slice(0, 120)
        _ -> nil
      end

    popularity_rank =
      case Map.get(m, "popularity_rank") do
        r when is_integer(r) -> r
        _ -> @popularity_rank_fallback
      end

    if label != "" and style != "" and slug != "" do
      %{
        slug: slug,
        label: label,
        emoji: String.trim(emoji),
        style: style,
        description: if(description == "", do: nil, else: description),
        loading_phrases: loading,
        popularity_rank: popularity_rank
      }
    end
  end

  defp coerce_voice(_), do: nil
```

- [ ] **Step 4: Implement `parse_voices/1` sort + cap change**

Find:

```elixir
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&coerce_voice/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.slug)
        |> Enum.take(6)

      _ ->
        []
    end
```

Replace with:

```elixir
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&coerce_voice/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.slug)
        |> Enum.sort_by(& &1.popularity_rank)
        |> Enum.take(10)

      _ ->
        []
    end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_test.exs`
Expected: PASS, including the 5 new tests and all pre-existing tests in the file (in particular the `loading_phrases` tests still pass since those JSON fixtures omit `popularity_rank`, which now defaults to `999_999`).

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "feat: parse and rank-sort popularity_rank, cap generated personas at 10"
```

---

### Task 4: Migration + `GameVoice` schema — add `popularity_rank`

**Files:**
- Create: `priv/repo/migrations/20260705120000_add_popularity_rank_to_game_voices.exs`
- Modify: `lib/rule_maven/voices/game_voice.ex`

**Interfaces:**
- Produces: `game_voices.popularity_rank` (nullable `:integer` column); `GameVoice` schema field `:popularity_rank, :integer`, castable via `GameVoice.changeset/2`. Task 5 relies on this cast accepting `:popularity_rank` in its `attrs` map.

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260705120000_add_popularity_rank_to_game_voices.exs`:

```elixir
defmodule RuleMaven.Repo.Migrations.AddPopularityRankToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      add :popularity_rank, :integer
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `== Running ... AddPopularityRankToGameVoices.change/0 forward` then success, no errors.

- [ ] **Step 3: Update `GameVoice` schema**

In `lib/rule_maven/voices/game_voice.ex`, find:

```elixir
    # Short user-facing blurb ("who is this persona?") shown in the voice menu.
    field :description, :string
    field :loading_phrases, {:array, :string}, default: []
```

Replace with:

```elixir
    # Short user-facing blurb ("who is this persona?") shown in the voice menu.
    field :description, :string
    field :loading_phrases, {:array, :string}, default: []
    # LLM-judged rank among this game's fans; 1 = most popular. Drives default
    # sort order in the voice picker (see Voices.game_voice_defs/1).
    field :popularity_rank, :integer
```

Find:

```elixir
  def changeset(gv, attrs) do
    gv
    |> cast(attrs, [
      :game_id,
      :slug,
      :label,
      :emoji,
      :style,
      :description,
      :loading_phrases,
      :source,
      :position
    ])
    |> validate_required([:game_id, :slug, :label, :emoji, :style])
    |> unique_constraint([:game_id, :slug])
  end
```

Replace with:

```elixir
  def changeset(gv, attrs) do
    gv
    |> cast(attrs, [
      :game_id,
      :slug,
      :label,
      :emoji,
      :style,
      :description,
      :loading_phrases,
      :popularity_rank,
      :source,
      :position
    ])
    |> validate_required([:game_id, :slug, :label, :emoji, :style])
    |> unique_constraint([:game_id, :slug])
  end
```

- [ ] **Step 4: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260705120000_add_popularity_rank_to_game_voices.exs lib/rule_maven/voices/game_voice.ex
git commit -m "feat: add popularity_rank column to game_voices"
```

---

### Task 5: `Voices.replace_generated/2` + `game_voice_defs/1` — persist and order by rank

**Files:**
- Modify: `lib/rule_maven/voices.ex` (`replace_generated/2` around lines 436–482, `game_voice_defs/1` around lines 199–223)
- Test: `test/rule_maven/voices_test.exs`

**Interfaces:**
- Consumes: `GameVoice.changeset/2` now accepting `:popularity_rank` (Task 4); `LLM.parse_voices/1` output maps now including `:popularity_rank` (Task 3).
- Produces: `Voices.game_voice_defs/1` return maps now include `popularity_rank` alongside existing keys (`slug, label, emoji, style, description, loading_phrases`); ordering changes from `position`-first to `popularity_rank`-first with `position` as tiebreaker. `Voices.replace_generated/2` keeps its existing `(game_id, [%{slug, label, emoji, style, description?, loading_phrases?}]) :: :ok` signature — `popularity_rank` is an optional key in each voice map, defaulting to `nil` if absent (e.g. hand-authored test fixtures that don't set it).

- [ ] **Step 1: Write failing tests**

Add to `test/rule_maven/voices_test.exs`, as a new `describe` block after `"replace_generated stability"` (after its closing `end`, i.e. after line 233):

```elixir
  describe "popularity_rank" do
    test "persists popularity_rank and orders game_voice_defs by it ascending" do
      g = game()

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "c", label: "C", emoji: "🙂", style: "x", popularity_rank: 3},
          %{slug: "a", label: "A", emoji: "🙂", style: "x", popularity_rank: 1},
          %{slug: "b", label: "B", emoji: "🙂", style: "x", popularity_rank: 2}
        ])

      gen_ids =
        Voices.for_game(g)
        |> Enum.filter(&String.starts_with?(&1.id, "g:"))
        |> Enum.map(& &1.id)

      assert gen_ids == ["g:a", "g:b", "g:c"]
    end

    test "changing only popularity_rank does not clear cached restyles" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly", popularity_rank: 5}
        ])

      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly", popularity_rank: 1}
        ])

      row = Repo.get_by!(GameVoice, game_id: g.id, slug: "herald")
      assert row.popularity_rank == 1
      assert Voices.get(q.id, "g:herald") == "hark!"
    end

    test "missing popularity_rank does not crash replace_generated" do
      g = game()

      assert :ok =
               Voices.replace_generated(g.id, [
                 %{slug: "plain", label: "Plain", emoji: "🙂", style: "x"}
               ])

      row = Repo.get_by!(GameVoice, game_id: g.id, slug: "plain")
      assert row.popularity_rank == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: the 3 new tests FAIL — first test fails the ordering assertion (currently ordered by `position`, i.e. insertion order `c, a, b`), second/third fail because `popularity_rank` isn't cast/persisted yet.

- [ ] **Step 3: Update `replace_generated/2` attrs map**

In `lib/rule_maven/voices.ex`, find:

```elixir
      attrs = %{
        game_id: game_id,
        slug: v.slug,
        label: v.label,
        emoji: v.emoji,
        style: v.style,
        description: Map.get(v, :description),
        loading_phrases: Map.get(v, :loading_phrases, []),
        source: "generated",
        position: idx
      }
```

Replace with:

```elixir
      attrs = %{
        game_id: game_id,
        slug: v.slug,
        label: v.label,
        emoji: v.emoji,
        style: v.style,
        description: Map.get(v, :description),
        loading_phrases: Map.get(v, :loading_phrases, []),
        popularity_rank: Map.get(v, :popularity_rank),
        source: "generated",
        position: idx
      }
```

(No change needed to the cache-invalidation `if old_style != v.style or old_label != v.label` check right below — it already ignores rank by construction.)

- [ ] **Step 4: Update `game_voice_defs/1` query and mapping**

Find:

```elixir
  def game_voice_defs(game_id) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id,
        order_by: [asc: gv.position, asc: gv.id],
        select: %{
          slug: gv.slug,
          label: gv.label,
          emoji: gv.emoji,
          style: gv.style,
          description: gv.description,
          loading_phrases: gv.loading_phrases
        }
    )
    |> Enum.map(fn gv ->
      %{
        id: @game_prefix <> gv.slug,
        label: gv.label,
        emoji: gv.emoji,
        style: gv.style,
        description: gv.description,
        loading_phrases: gv.loading_phrases || []
      }
    end)
  end
```

Replace with:

```elixir
  def game_voice_defs(game_id) do
    Repo.all(
      from gv in GameVoice,
        where: gv.game_id == ^game_id,
        order_by: [
          asc: fragment("? NULLS LAST", gv.popularity_rank),
          asc: gv.position,
          asc: gv.id
        ],
        select: %{
          slug: gv.slug,
          label: gv.label,
          emoji: gv.emoji,
          style: gv.style,
          description: gv.description,
          loading_phrases: gv.loading_phrases,
          popularity_rank: gv.popularity_rank
        }
    )
    |> Enum.map(fn gv ->
      %{
        id: @game_prefix <> gv.slug,
        label: gv.label,
        emoji: gv.emoji,
        style: gv.style,
        description: gv.description,
        loading_phrases: gv.loading_phrases || [],
        popularity_rank: gv.popularity_rank
      }
    end)
  end
```

(`NULLS LAST` matters because a real Postgres `ORDER BY ... ASC` already puts `NULL` last by default in Postgres — this is written explicitly so a row with no rank, e.g. a hand-inserted or pre-migration voice, never jumps ahead of ranked ones regardless of backend defaults.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: PASS, all tests including the 3 new ones and the pre-existing `"for_game / resolution"` / `"replace_generated stability"` blocks (those fixtures omit `popularity_rank`, which now persists as `nil` and sorts last — harmless since those tests only assert single-voice presence/label, not multi-voice order).

- [ ] **Step 6: Full test suite check**

Run: `mix test`
Expected: PASS. No other test in the suite depends on the old `game_voice_defs/1` map shape lacking `popularity_rank` (an added key never breaks pattern matches on `%{}` since Elixir map matches are structural-subset, not exact).

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/voices.ex test/rule_maven/voices_test.exs
git commit -m "feat: persist popularity_rank and order voice picker by it"
```

---

## Post-plan verification

- [ ] Run `mix test` once more at the end to confirm the whole suite is green.
- [ ] Run `mix compile --warnings-as-errors` once more to confirm zero warnings across all touched files.
- [ ] Manually trigger `VoiceSuggestionsWorker` for a real game (e.g. via IEx: `RuleMaven.Workers.VoiceSuggestionsWorker.enqueue(game_id)` or however the existing dev workflow re-triggers it) and inspect `game_voices` rows for that game to confirm up to 10 rows land with non-null, contiguous-ish `popularity_rank` values from a live LLM call. Per [[verify-major-only]], this is worth a real check since it touches a live LLM prompt contract, not just internal code — but no browser/UI check is needed since the voice-picker ordering itself is exercised by the automated tests in Task 5.
