# Multi-citation Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Q&A answer carry a list of citations (one per distinct rulebook passage relied on) instead of exactly one, so multi-topic questions can cite every page they actually drew from.

**Architecture:** The LLM's JSON response schema gains a `"citations"` array (replacing the singular `citation`/`page`/`source` fields). `RuleMaven.LLM.decode_answer/1` parses it and mirrors the first entry into the existing scalar `cited_passage`/`cited_page`/`cited_source` fields so every pre-existing consumer (FAQ badge, admin table, `Trust.has_citation?`, answer-pool cache) keeps working unchanged. `RuleMaven.Workers.AskWorker` runs each citation through the existing per-citation page-recovery/source-canonicalization logic, validates each against the retrieved chunks via a new `Citations.valid_citations/2`, drops ungrounded ones, and persists the survivors to a new `citations` jsonb column on `questions_log` (plus the scalar mirror, now derived from `survivors |> List.first()`). The LiveView Q&A thread renders one citation block per surviving citation instead of one fixed block.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto (Postgres, jsonb), ExUnit.

## Global Constraints

- No cap on citation count — the model decides how many distinct passages to cite; no code-level max-length enforcement (per design decision).
- Backward compatible: existing scalar `cited_passage`/`cited_page`/`cited_source` columns and every consumer that reads them (FAQ badge `faq.ex:326`, admin table `admin_live/questions.ex:490`, `Trust.has_citation?/1`, `llm.ex` pool-cache row) must continue to work without modification — they're driven by the mirrored first/primary citation.
- Citation entries are stored and passed around as **string-keyed maps** (`%{"quote" => ..., "page" => ..., "source" => ...}`) throughout — matches how Postgrex/Ecto returns `{:array, :map}` jsonb data on reload, so in-memory (pre-save) and reloaded (post-save) shapes are identical. Do not mix in atom keys.
- FAQ badge / admin table intentionally keep showing only the primary citation — multi-citation display is a Q&A-thread-view-only enhancement (out of scope for those two surfaces, per spec).
- A citation that fails grounding (`Citations.valid?/4` false) is dropped from the persisted/displayed list entirely — it does not invalidate the other citations in the same answer.

---

### Task 1: Add `citations` jsonb column + schema field

**Files:**
- Create: `priv/repo/migrations/20260704180000_add_citations_to_questions_log.exs`
- Modify: `lib/rule_maven/games/question_log.ex`
- Test: `test/rule_maven/games_document_test.exs` is unrelated — no dedicated schema test exists for `question_log.ex`; verify via `mix ecto.migrate` + `iex` round-trip in the step below instead.

**Interfaces:**
- Produces: `QuestionLog` struct gains `citations` field, `{:array, :map}`, default `[]`. Castable via `changeset/2`. Later tasks read/write `question_log.citations` as a list of `%{"quote" => string | nil, "page" => integer | nil, "source" => string | nil}` maps.

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.AddCitationsToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :citations, {:array, :map}, default: [], null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `== Running ... AddCitationsToQuestionsLog.change/0 forward` then `:ok`, migration appears in `mix ecto.migrations` as `up`.

- [ ] **Step 3: Add the field to the schema and changeset cast list**

In `lib/rule_maven/games/question_log.ex`, add the field next to `cited_source` (after line 14):

```elixir
    field :cited_source, :string
    field :citations, {:array, :map}, default: []
```

And add `:citations` to the `cast/3` list in `changeset/2` (next to `:cited_source`):

```elixir
      :cited_page,
      :cited_source,
      :citations,
      :question_embedding,
```

- [ ] **Step 4: Verify the round-trip in `iex`**

Run: `mix run -e '
{:ok, game} = RuleMaven.Games.create_game(%{name: "CitationRoundTripTest"})
{:ok, ql} = RuleMaven.Games.log_question(%{game_id: game.id, question: "q", answer: "a", user_id: nil})
{:ok, updated} = RuleMaven.Games.log_question_update(ql, %{citations: [%{"quote" => "x", "page" => 3, "source" => "Core"}]})
reloaded = RuleMaven.Games.get_question_log(updated.id)
IO.inspect(reloaded.citations)
'`
Expected: `[%{"page" => 3, "quote" => "x", "source" => "Core"}]` printed (string keys, values round-tripped).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260704180000_add_citations_to_questions_log.exs lib/rule_maven/games/question_log.ex
git commit -m "feat: add citations jsonb column to questions_log"
```

---

### Task 2: `Citations.valid_citations/2`

**Files:**
- Modify: `lib/rule_maven/games/citations.ex`
- Test: `test/rule_maven/citations_test.exs`

**Interfaces:**
- Consumes: `Citations.valid?/4` (existing, unchanged signature `valid?(passage, cited_page, source_chunks, cited_source)`).
- Produces: `Citations.valid_citations(citations, source_chunks)` — `citations` is a list of `%{"quote" => string | nil, "page" => integer | nil, "source" => string | nil}`; returns the subset that pass `valid?/4`, in original order. Non-list input returns `[]`. This is what `AskWorker` (Task 6) calls to filter the model's citation list before persisting/displaying it.

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven/citations_test.exs`, before the final `end`:

```elixir
  describe "valid_citations/2" do
    @chunks [
      "[Page 3] Each player draws three cards at the start of their turn.",
      "[Page 7] Scoring happens at the end of the round, summing all face-up tokens."
    ]

    test "keeps only the grounded entries, preserving order" do
      citations = [
        %{"quote" => "draws three cards at the start of their turn", "page" => 3, "source" => nil},
        %{"quote" => "the dragon devours two villages each dawn", "page" => 3, "source" => nil},
        %{"quote" => "summing all face-up tokens", "page" => 7, "source" => nil}
      ]

      assert Citations.valid_citations(citations, @chunks) == [
               %{"quote" => "draws three cards at the start of their turn", "page" => 3, "source" => nil},
               %{"quote" => "summing all face-up tokens", "page" => 7, "source" => nil}
             ]
    end

    test "empty input yields empty output" do
      assert Citations.valid_citations([], @chunks) == []
    end

    test "all-ungrounded input yields empty output" do
      citations = [%{"quote" => "invented nonsense", "page" => 99, "source" => nil}]
      assert Citations.valid_citations(citations, @chunks) == []
    end

    test "non-list input yields empty output" do
      assert Citations.valid_citations(nil, @chunks) == []
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/rule_maven/citations_test.exs -v --only test`
Expected: FAIL — `UndefinedFunctionError` for `Citations.valid_citations/2` (function not defined yet).

- [ ] **Step 3: Implement `valid_citations/2`**

In `lib/rule_maven/games/citations.ex`, add after `canonical_source/2` (after line 80, before `defp to_chunk_maps`):

```elixir
  @doc """
  Filters a list of `%{"quote" => , "page" => , "source" => }` citation maps
  down to the ones grounded in `source_chunks`, via `valid?/4`. Order is
  preserved; ungrounded entries are dropped silently rather than failing the
  whole list — one hallucinated citation among several good ones shouldn't
  wipe out the rest of the answer's citations.
  """
  def valid_citations(citations, source_chunks) when is_list(citations) do
    Enum.filter(citations, fn c ->
      valid?(c["quote"], c["page"], source_chunks, c["source"])
    end)
  end

  def valid_citations(_citations, _source_chunks), do: []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/rule_maven/citations_test.exs -v`
Expected: PASS, all tests including the new `valid_citations/2` describe block.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games/citations.ex test/rule_maven/citations_test.exs
git commit -m "feat: add Citations.valid_citations/2 for multi-citation filtering"
```

---

### Task 3: Update the answer prompt schema

**Files:**
- Modify: `lib/rule_maven/prompts.ex`

**Interfaces:**
- Produces: the `@answer` prompt template's JSON schema now describes `"citations": [{...}]` instead of singular `citation`/`page`/`source`. `RuleMaven.Prompts.render("answer", bindings)` (unchanged signature) returns the updated text — Task 4's `decode_answer/1` is what actually parses the model's reply against this new shape.

- [ ] **Step 1: Replace the CITATION RULES and OUTPUT schema section**

In `lib/rule_maven/prompts.ex`, replace lines 49–71 (from `CITATION RULES` through the closing `Output valid JSON only...` line) with:

```
  CITATION RULES — how to fill "citations":
  - "citations" is an array. Add ONE entry per DISTINCT rulebook passage you actually relied on to compose "answer" — do not duplicate the same passage in two entries, and do not invent extra entries just to pad the list. A simple single-fact answer normally needs exactly one entry; an answer that draws on several different rules (e.g. "how is the d20 used" spanning multiple unrelated mechanics) needs one entry per mechanic.
  - "quote": copy the supporting text VERBATIM, character-for-character, from the RULEBOOK for that entry. Do NOT paraphrase, summarize, shorten, merge, or fix typos. It must be findable as an exact substring of the rulebook text. Quote the prose only — do NOT include the [Page N] marker itself in this string.
  - Quote ONLY from the RULEBOOK below. NEVER quote from the RECENT CONVERSATION or from your own previous answers.
  - "page": the integer page number of that entry's quoted text, read from the [Page N] marker that immediately precedes it in the RULEBOOK. Every non-refusal answer MUST have at least one citation with a page set. Use ONLY a number that actually appears in a [Page N] marker — NEVER invent, guess, or renumber. If a quote spans pages, use the page where it begins.
  - "source": the exact source name from the header the entry was cited from (e.g. "Core rules").

  AUTHORITY: sources are grouped under headers. When sources conflict, follow
  this order (highest wins): ERRATA > FAQ > RULEBOOK > SCENARIO > HOWTO >
  REFERENCE > NOTES > OTHER. An EXPANSION source overrides a BASE GAME source
  of the same type for content involving that expansion. If you relied on a
  higher-authority source over a contradicting lower one, say so briefly
  (e.g. "The rulebook says X, but the FAQ clarifies Y").

  OUTPUT — respond with ONE json object (a single JSON object) and nothing else (no markdown fences, no prose around it). Schema:
  {
    "answer": string,            // the answer in plain English. Use markdown (**bold**, bullet lists). Concise: 1-3 sentences plus optional list. On refusal this is exactly: "The rulebook does not cover this question."
    "verdict": string,           // classify the answer for a verdict stamp. Exactly one of: "legal" (the asked action/move IS permitted by the rules), "illegal" (the asked action/move is NOT permitted / forbidden), "silent" (use ONLY when refusing — rulebook does not cover it), "info" (a factual/explanatory answer that is not a yes/no legality question, e.g. "how does scoring work"). If the question is not about whether something is allowed, use "info". On refusal always "silent".
    "citations": [                // follow CITATION RULES above exactly. Empty array only when refusing.
      { "quote": string, "page": integer, "source": string }
    ],
    "followups": [string],       // 2-3 natural next questions a player might ask. Empty array on refusal.
    "also_asked": [string]       // if the user's message contained more than one distinct question, the exact text of the additional questions (answer only the FIRST in "answer"). Empty array otherwise.
  }
  Output valid JSON only. Do not wrap it in ``` fences.
```

- [ ] **Step 2: Also update the refusal-rule reference to citations**

Line 40 currently reads:

```
  5. When refusing, set "answer" to exactly the refusal phrase, leave "citation" empty, and set "followups" and "also_asked" to empty arrays.
```

Replace it with:

```
  5. When refusing, set "answer" to exactly the refusal phrase, set "citations" to an empty array, and set "followups" and "also_asked" to empty arrays.
```

- [ ] **Step 3: Compile to confirm the module still builds**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly, no warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/rule_maven/prompts.ex
git commit -m "feat: update answer prompt schema to a citations array"
```

---

### Task 4: `LLM.decode_answer/1` parses the citations array

**Files:**
- Modify: `lib/rule_maven/llm.ex`
- Test: `test/rule_maven/llm_test.exs`

**Interfaces:**
- Consumes: nothing new — reuses existing private helpers `coerce_page/1`, `nilable_string/1`, `trimmed_string/1`, `coerce_verdict/1`, `string_list/1` in the same module.
- Produces: `LLM.decode_answer/1` return map gains a `:citations` key — a list of `%{"quote" => string | nil, "page" => integer | nil, "source" => string | nil}` maps (empty list on refusal, on a JSON-decode failure, or when `citations` is missing/malformed). The map's `:cited_passage`/`:cited_page`/`:cited_source` keys are now derived from `List.first(citations)` instead of the removed singular `"citation"`/`"page"`/`"source"` JSON fields — every existing caller that reads those three keys off the decoded map keeps working unchanged.

- [ ] **Step 1: Write the failing tests**

Replace the existing `describe "decode_answer"` block in `test/rule_maven/llm_test.exs` (lines 66–74) with:

```elixir
  describe "decode_answer" do
    test "parses a single-entry citations array and mirrors the scalar fields" do
      json =
        ~s({"answer":"x","citations":[{"quote":"y","page":3,"source":"X errata"}],"verdict":"clear"})

      result = LLM.decode_answer(json)

      assert result[:citations] == [%{"quote" => "y", "page" => 3, "source" => "X errata"}]
      assert result[:cited_passage] == "y"
      assert result[:cited_page] == 3
      assert result[:cited_source] == "X errata"
    end

    test "parses a multi-entry citations array, mirroring only the first" do
      json =
        ~s({"answer":"x","citations":[{"quote":"first quote","page":5,"source":"Core"},{"quote":"second quote","page":11,"source":"Core"}]})

      result = LLM.decode_answer(json)

      assert length(result[:citations]) == 2
      assert Enum.at(result[:citations], 1)["page"] == 11
      assert result[:cited_passage] == "first quote"
      assert result[:cited_page] == 5
    end

    test "missing citations key yields empty list and nil scalar fields" do
      json = ~s({"answer":"The rulebook does not cover this question."})
      result = LLM.decode_answer(json)

      assert result[:citations] == []
      assert result[:cited_passage] == nil
      assert result[:cited_page] == nil
    end

    test "malformed (non-list) citations yields empty list" do
      json = ~s({"answer":"x","citations":"not a list"})
      result = LLM.decode_answer(json)

      assert result[:citations] == []
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs -v --only test`
Expected: FAIL — `result[:citations]` is `nil` (key not produced yet), and the old singular JSON keys no longer populate the scalar mirror fields correctly for the new schema shape.

- [ ] **Step 3: Implement the parsing**

In `lib/rule_maven/llm.ex`, replace the body of `decode_answer/1` (the `case json_object(content) do` block, currently lines ~944–967) with:

```elixir
    case json_object(content) do
      {:ok, map} ->
        citations = parse_citations(map["citations"])
        first = List.first(citations) || %{}

        %{
          answer: trimmed_string(map["answer"]),
          citations: citations,
          cited_passage: first["quote"],
          cited_page: first["page"],
          cited_source: first["source"],
          verdict: coerce_verdict(map["verdict"]),
          followups: string_list(map["followups"]),
          also_asked: string_list(map["also_asked"])
        }

      :error ->
        %{
          answer: String.trim(content),
          citations: [],
          cited_passage: nil,
          cited_page: nil,
          cited_source: nil,
          verdict: nil,
          followups: [],
          also_asked: []
        }
    end
```

Then add the new private helper right after `decode_answer/1` (before `defp json_object`):

```elixir
  # Normalizes the model's raw "citations" JSON value into a list of
  # string-keyed maps, tolerating a missing/non-list value or malformed
  # entries. An entry with no usable content (no quote, page, or source) is
  # dropped rather than kept as a placeholder.
  defp parse_citations(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{} = c ->
        %{
          "quote" => nilable_string(c["quote"]),
          "page" => coerce_page(c["page"]),
          "source" => nilable_string(c["source"])
        }

      _ ->
        %{"quote" => nil, "page" => nil, "source" => nil}
    end)
    |> Enum.reject(&(&1["quote"] == nil and &1["page"] == nil and &1["source"] == nil))
  end

  defp parse_citations(_), do: []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/rule_maven/llm_test.exs -v`
Expected: PASS, all tests in the file including `decode_answer`, `response parsing`, and `system prompt` describes (the latter two use the `mock_llm` seam and don't touch `decode_answer`, so they're unaffected).

- [ ] **Step 5: Pass `citations` through in `ask/5`**

In `lib/rule_maven/llm.ex`, in `call_llm/7` (around line 163), the `{:ok, %{answer: answer, cited_passage: passage} = llm_result} ->` branch currently returns a map that does not include `citations`. Add it — modify the returned map (around lines 164–184) by inserting the line `citations: llm_result[:citations] || [],` immediately after `cited_source: llm_result[:cited_source],`:

```elixir
      {:ok, %{answer: answer, cited_passage: passage} = llm_result} ->
        {:ok,
         %{
           answer: answer,
           cited_passage: passage,
           cited_page: llm_result[:cited_page],
           cited_source: llm_result[:cited_source],
           citations: llm_result[:citations] || [],
           verdict: llm_result[:verdict],
```

(Leave everything else in that map unchanged.)

- [ ] **Step 6: Run the full LLM test file again**

Run: `mix test test/rule_maven/llm_test.exs -v`
Expected: PASS. The `mock_llm`-based tests supply `cited_passage` directly without a `citations` key — `llm_result[:citations] || []` correctly defaults to `[]` for them, so `result.citations == []` in those cases; this is expected and handled downstream in Task 6.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "feat: parse citations array in LLM.decode_answer and thread through ask/5"
```

---

### Task 5: `AskWorker` processes, validates, and persists the citation list

**Files:**
- Modify: `lib/rule_maven/workers/ask_worker.ex`
- Test: create `test/rule_maven/workers/ask_worker_citations_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Games.Citations.valid_citations/2` (Task 2), `RuleMaven.Games.Citations.canonical_source/2` (existing), the existing private `parse_cited_page/1` and `infer_page_from_chunks/2` in this same file (unchanged).
- Produces: the `questions_log` row updated by `AskWorker.perform/1` now has `citations` populated (validated, processed list) and `cited_passage`/`cited_page`/`cited_source`/`citation_valid` derived from `List.first(that validated list)` instead of the raw single citation — this is the one deliberate behavior change from today: a citation that fails grounding is no longer shown anywhere (previously it was stored/displayed with `citation_valid: false` as the only signal). No test currently locks in the old "show it anyway" behavior (confirmed: no test in the repo asserts `cited_page` is populated when `citation_valid` is false), so this is safe to tighten.

- [ ] **Step 1: Write the failing tests**

`ask_worker_dedup_test.exs` establishes the convention this repo uses: no `Oban.Testing`, just a local `perform/1` helper that builds a fake `%Oban.Job{}` and calls `AskWorker.perform/1` directly, plus `Application.put_env(:rule_maven, :llm_mock, fn _ -> ... end)` / `:embed_mock` for the LLM and embedding seams. Follow that pattern. Create `test/rule_maven/workers/ask_worker_citations_test.exs`:

```elixir
defmodule RuleMaven.Workers.AskWorkerCitationsTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Workers.AskWorker

  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  defp put_chunk(doc, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  setup do
    {:ok, game} = Games.create_game(%{name: "CitationTestGame #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    put_chunk(doc, "[Page 5]\nRoll the d20 to determine the first player.", List.duplicate(0.1, 768))
    put_chunk(doc, "[Page 11]\nDamage the Beholder's eyestalks by rolling the d20.", List.duplicate(0.1, 768))

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        question: "How is the d20 used?",
        answer: "Thinking...",
        user_id: nil
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    %{game: game, ql: ql}
  end

  test "persists multiple grounded citations and mirrors the first into scalar fields", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player and damages the Beholder's eyestalks.",
         citations: [
           %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"},
           %{"quote" => "Damage the Beholder's eyestalks by rolling the d20.", "page" => 11, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert length(updated.citations) == 2
    assert Enum.at(updated.citations, 0)["page"] == 5
    assert Enum.at(updated.citations, 1)["page"] == 11
    assert updated.cited_page == 5
    assert updated.cited_passage =~ "first player"
    assert updated.citation_valid == true
  end

  test "drops an ungrounded citation but keeps the grounded ones", %{game: game, ql: ql} do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player.",
         citations: [
           %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"},
           %{"quote" => "the dragon devours two villages each dawn", "page" => 999, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert length(updated.citations) == 1
    assert Enum.at(updated.citations, 0)["page"] == 5
    assert updated.citation_valid == true
  end

  test "all-ungrounded citations yield an empty list and citation_valid false", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "Something.",
         citations: [%{"quote" => "invented nonsense", "page" => 999, "source" => nil}],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert updated.citations == []
    assert updated.cited_page == nil
    assert updated.citation_valid == false
  end
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/rule_maven/workers/ask_worker_citations_test.exs -v`
Expected: FAIL — `updated.citations` is `[]` for all three (field exists from Task 1 but nothing populates it yet), and/or `updated.cited_page` reflects only the old single-citation code path.

- [ ] **Step 3: Implement the processing/validation/persistence**

In `lib/rule_maven/workers/ask_worker.ex`, replace lines 159–217 (from `raw_passage = llm_result[:cited_passage]` through the `cited_source =` block ending at line 217) with:

```elixir
                raw_citations =
                  case llm_result[:citations] do
                    list when is_list(list) and list != [] ->
                      list

                    _ ->
                      # Legacy/mock path: only the singular scalar fields were
                      # supplied. Wrap them so downstream processing is uniform.
                      if llm_result[:cited_passage] || llm_result[:cited_page] ||
                           llm_result[:cited_source] do
                        [
                          %{
                            "quote" => llm_result[:cited_passage],
                            "page" => llm_result[:cited_page],
                            "source" => llm_result[:cited_source]
                          }
                        ]
                      else
                        []
                      end
                  end

                processed_citations =
                  Enum.map(raw_citations, &process_citation(&1, llm_result[:source_chunks]))

                valid_citations =
                  RuleMaven.Games.Citations.valid_citations(
                    processed_citations,
                    llm_result[:source_chunks]
                  )

                citation_valid = valid_citations != []

                primary =
                  List.first(valid_citations) || %{"quote" => nil, "page" => nil, "source" => nil}

                passage = primary["quote"]
                cited_page = primary["page"]
                cited_source = primary["source"]
```

Then update `update_attrs` (currently lines 219–238) to add the new `citations:` key — insert it right after `cited_source: cited_source,`:

```elixir
                  cited_passage: passage,
                  cited_page: cited_page,
                  cited_source: cited_source,
                  citations: valid_citations,
                  citation_valid: citation_valid,
```

Finally, add the new private helper `process_citation/2` near the other citation-related private functions (right before `defp parse_cited_page(nil), do: nil` — currently line 436):

```elixir
  # Per-citation-entry cleanup: strips [Page N]/(Page N) markers from the
  # quote (they're only needed to recover the page below), recovers a missing
  # page the same way the old single-citation path did (trust the model's
  # own page first, else parse it out of the raw quote, else infer it by
  # matching the quote back to its source chunk), and canonicalizes the
  # source label against the actual retrieved chunk labels.
  defp process_citation(%{} = c, source_chunks) do
    raw_quote = c["quote"]

    quote_clean =
      if raw_quote do
        raw_quote
        |> String.replace(~r/\[Page\s*\d+\]/i, "")
        |> String.replace(~r/\(Page\s*\d+\)/i, "")
        |> String.trim()
      end

    resolved_page =
      c["page"] ||
        parse_cited_page(raw_quote) ||
        infer_page_from_chunks(quote_clean, source_chunks)

    resolved_source = RuleMaven.Games.Citations.canonical_source(c["source"], source_chunks)

    %{"quote" => quote_clean, "page" => resolved_page, "source" => resolved_source}
  end
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `mix test test/rule_maven/workers/ask_worker_citations_test.exs -v`
Expected: PASS, all three tests.

- [ ] **Step 5: Run the full worker/ask test suite to check for regressions**

Run: `mix test test/rule_maven/workers/ -v 2>&1 | tee /tmp/ask_worker_tests.log; tail -30 /tmp/ask_worker_tests.log`
Expected: PASS across all worker tests (existing dedup/killswitch tests use the same mock seam with scalar `cited_passage` fields, which now flow through the legacy-wrap branch of `raw_citations` — should be unaffected). Investigate and fix any failure before moving on; do not skip.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/workers/ask_worker.ex test/rule_maven/workers/ask_worker_citations_test.exs
git commit -m "feat: validate and persist multi-citation lists in AskWorker"
```

---

### Task 6: Render multiple citation blocks in the Q&A thread

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex`

**Interfaces:**
- Consumes: `msg[:citations]` (list of `%{"quote" =>, "page" =>, "source" =>}` string-keyed maps, from `question_log.citations`) and, as a fallback, `msg[:cited_passage]`/`msg[:cited_page]`/`msg[:cited_source]` for rows without a populated `citations` list (pre-migration history or the legacy-wrap path).
- Produces: the Q&A thread view renders one citation block per entry returned by a new private `citation_list/1` helper — no new public interface for other modules.

- [ ] **Step 1: Add `citations` to the conversation message maps**

In `build_conversation/1` (`lib/rule_maven_web/live/game_live/show.ex`), add `citations: g.primary.citations,` to the `assistant_msg` map (after line 340, `cited_source: g.primary.cited_source,`):

```elixir
        cited_passage: g.primary.cited_passage,
        cited_page: g.primary.cited_page,
        cited_source: g.primary.cited_source,
        citations: g.primary.citations,
```

And add `citations: h.citations,` to the `history_msgs` map (after line 367, `cited_source: h.cited_source,`):

```elixir
            cited_passage: h.cited_passage,
            cited_page: h.cited_page,
            cited_source: h.cited_source,
            citations: h.citations,
```

- [ ] **Step 2: Add `citations` to the `:ask_complete` live-update path**

In `handle_info({:ask_complete, data}, socket)`, in the block that patches the assistant message once the answer is ready (currently lines 1289–1309), add `|> Map.put(:citations, ql.citations)` right after `|> Map.put(:cited_source, data[:cited_source] || ql.cited_source)` (line 1298):

```elixir
                |> Map.put(:cited_source, data[:cited_source] || ql.cited_source)
                |> Map.put(:citations, ql.citations)
```

- [ ] **Step 3: Add the `citation_list/1` helper**

Add this private function anywhere among the other small render-helper private functions in `show.ex` (e.g. near other `defp` helpers used only by the template — grep the file for an existing `defp render_markdown` or similar to place it alongside):

```elixir
  # A message's citation list, preferring the new multi-citation field and
  # falling back to the legacy scalar fields for rows saved before the
  # `citations` column existed (or the mock/legacy-wrap path in AskWorker).
  defp citation_list(msg) do
    case msg[:citations] do
      list when is_list(list) and list != [] ->
        list

      _ ->
        if msg[:cited_passage] do
          [%{"quote" => msg.cited_passage, "page" => msg[:cited_page], "source" => msg[:cited_source]}]
        else
          []
        end
    end
  end
```

- [ ] **Step 4: Replace the single citation block with a loop over `citation_list/1`**

Replace lines 2249–2269 (the `<%= if msg[:cited_passage] && msg.content != "Thinking..." do %>` block through its closing `<% end %>`) with:

```heex
                  <%= if msg.content != "Thinking..." do %>
                    <%= for c <- citation_list(msg) do %>
                      <% on_user = msg.role == :user %>
                      <figure style={"margin:0.75rem 0 0;border-radius:0.5rem;overflow:hidden;border:1px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 25%,transparent)", else: "var(--border)"};background:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 10%,transparent)", else: "var(--bg-subtle)"}"}>
                        <%= if c["page"] do %>
                          <figcaption style={"display:flex;align-items:center;gap:0.35rem;padding:0.3rem 0.6rem;font-size:0.66rem;font-weight:700;letter-spacing:0.02em;text-transform:uppercase;border-bottom:1px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 15%,transparent)", else: "var(--border-subtle)"};color:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 85%,transparent)", else: "var(--text-muted)"}"}>
                            <span aria-hidden="true">&#128206;</span>
                            {c["source"] || "Rulebook"} &middot; p.{c["page"]}
                          </figcaption>
                        <% end %>
                        <blockquote style={"margin:0;padding:0.55rem 0.7rem 0.55rem 0.85rem;border-left:3px solid #{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 50%,transparent)", else: "var(--accent)"};font-style:italic;font-size:0.78rem;line-height:1.5;word-break:break-word;color:#{if on_user, do: "color-mix(in srgb,var(--accent-text,#fff) 92%,transparent)", else: "var(--text)"}"}>
                          {render_markdown(String.trim(c["quote"] || ""))}
                        </blockquote>
                      </figure>
                    <% end %>
                  <% end %>
```

(This drops the `msg[:cited_html_link]` block that was previously inside — grep confirms no code anywhere ever sets that key, so it was dead markup; nothing observable changes.)

- [ ] **Step 5: Compile and run the existing LiveView test suite**

Run: `mix compile --warnings-as-errors && mix test test/rule_maven_web/live/game_live_citation_source_test.exs -v`
Expected: compiles clean; the existing citation-source LiveView test passes unchanged (it exercises the single-citation legacy path, which the fallback branch of `citation_list/1` still serves identically).

- [ ] **Step 6: Manual verification**

Start the app (`mix phx.server`), open a Horrified: Dungeons & Dragons game page, ask "How is the d20 used in this game?", and regenerate the answer if it was already asked (↻ Regenerate button). Confirm the answer now renders more than one citation block, including a p.11 Beholder citation alongside the p.5 general-rules citation.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex
git commit -m "feat: render multiple citation blocks in the Q&A thread"
```

---

## Post-plan cleanup

Run the full test suite once more after all six tasks to confirm nothing elsewhere regressed:

```bash
mix test 2>&1 | tee /tmp/full_suite.log; tail -40 /tmp/full_suite.log
```

Expected: all tests pass. Investigate and fix any failure before considering this plan complete — do not run the suite twice without addressing failures in between.
