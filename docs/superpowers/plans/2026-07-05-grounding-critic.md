# Grounding Critic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch answers where the model cites a real rulebook passage but adds an unsupported consequence/claim past it, using a cheap heuristic gate escalated to a critic call, with a single re-ask before falling back to the existing refusal path.

**Architecture:** `RuleMaven.Games.Citations.suspicious?/2` (pure, free) flags an answer whose prose isn't plausibly grounded in its own cited quotes. On a flag, `RuleMaven.LLM.critique_grounding/3` (new, uses `model(:cheap)`, mirrors the existing `critique_cleanup/2` critic pattern) asks a cheap model for a `grounded`/`hallucinated` verdict. On `hallucinated`, `RuleMaven.LLM` re-runs the full answer call once with a warning appended to the system prompt, checks the retry the same way, and on a second failure discards it in favor of the existing "not covered" refusal text so the rest of the pipeline (`ask_worker.ex`) needs zero changes.

**Tech Stack:** Elixir/Phoenix, ExUnit, existing `RuleMaven.LLM` mock seam (`Application.put_env(:rule_maven, :llm_mock, fn body -> ... end)` / `mock_llm/1` test helper).

## Global Constraints

- No new `QuestionLog` fields or migration — reuses existing `verdict`/`refused` (per spec, "Data model" section).
- Grounding check runs only on the fresh-generation path (`call_llm/8`), never on pool/cache hits (per spec, "Approach" section — cache hits already passed this on first generation).
- Critic call uses `model(:cheap)` — no new model/config setting (per spec, "Step 2").
- Exactly one re-ask on a confirmed hallucination, no further retries (per spec, "Step 3").
- New prompt text goes through the `RuleMaven.Prompts` registry (DB-override mechanism), not a hardcoded string in `llm.ex` (per project convention already followed by every other prompt in `prompts.ex`).

---

### Task 1: `Citations.suspicious?/2` heuristic gate

**Files:**
- Modify: `lib/rule_maven/games/citations.ex`
- Test: `test/rule_maven/citations_test.exs`

**Interfaces:**
- Produces: `RuleMaven.Games.Citations.suspicious?(answer :: String.t() | nil, quotes :: [String.t()]) :: boolean()` — `quotes` is the list of cited quote strings pulled from the answer's own citations (nils already filtered out by the caller).

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/citations_test.exs` (append a new `describe` block at the end of the file, before the final `end`):

```elixir
  describe "suspicious?/2" do
    test "flags a trigger word not present in the cited quotes" do
      quotes = ["Move the Terror Marker up one space on the Terror Level Track."]

      answer =
        "Defeating a Hero or Citizen raises Terror. Defeating a Monster lowers it."

      assert Citations.suspicious?(answer, quotes)
    end

    test "does not flag a trigger word that's already in the quote" do
      quotes = ["If a Hero is defeated, move the Terror Marker up one space unless a Citizen was already lost."]
      answer = "Terror moves up one space unless a Citizen was already lost."

      refute Citations.suspicious?(answer, quotes)
    end

    test "flags an answer disproportionately longer than its citations" do
      quotes = ["Draw three cards."]

      answer =
        String.duplicate("This is extra elaboration not found in the source text. ", 10)

      assert Citations.suspicious?(answer, quotes)
    end

    test "does not flag a plain answer with no trigger words and reasonable length" do
      quotes = ["Each player draws three cards at the start of their turn."]
      answer = "Each player draws three cards at the start of their turn."

      refute Citations.suspicious?(answer, quotes)
    end

    test "refusal text with no citations is never flagged" do
      refute Citations.suspicious?("The rulebook does not cover this question.", [])
    end

    test "nil answer is never flagged" do
      refute Citations.suspicious?(nil, ["some quote"])
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/citations_test.exs`
Expected: FAIL — `Citations.suspicious?/2 is undefined or private`

- [ ] **Step 3: Implement `suspicious?/2`**

In `lib/rule_maven/games/citations.ex`, add the trigger-word list near the top (after `@min_needle_len`) and the public function + private helper at the end of the module (before the final `end`):

```elixir
  # Words that describe a rule's effect/consequence. Present in the answer but
  # absent from every cited quote is a strong signal the model added a claim
  # the citation doesn't actually support.
  @trigger_words ~w(
    lowers raises increases decreases unless instead always never must cannot
    before after only if requires prevents allows forbidden mandatory optional
  )

  # An answer whose prose isn't plausibly grounded in its own cited quotes:
  # either it uses a consequence/causal word the quotes never state, or it's
  # much longer than the quotes could support. Cheap (no LLM call) first-pass
  # gate — a true positive here gets escalated to `LLM.critique_grounding/3`.
  def suspicious?(answer, quotes) when is_binary(answer) do
    quotes = quotes |> List.wrap() |> Enum.filter(&is_binary/1)

    answer_norm = normalize(answer)
    combined_quote_norm = quotes |> Enum.join(" ") |> normalize()

    keyword_hit? =
      Enum.any?(@trigger_words, fn word ->
        contains_word?(answer_norm, word) and not contains_word?(combined_quote_norm, word)
      end)

    quote_word_count = combined_quote_norm |> String.split(" ", trim: true) |> length()
    answer_word_count = answer_norm |> String.split(" ", trim: true) |> length()

    length_ratio_hit? =
      quote_word_count > 0 and answer_word_count > quote_word_count * 2.5

    keyword_hit? or length_ratio_hit?
  end

  def suspicious?(_answer, _quotes), do: false

  defp contains_word?(text, word) do
    Regex.match?(~r/\b#{Regex.escape(word)}\b/, text)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/citations_test.exs`
Expected: PASS (all tests, old and new)

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games/citations.ex test/rule_maven/citations_test.exs
git commit -m "feat: add Citations.suspicious?/2 grounding heuristic"
```

---

### Task 2: `grounding_critic` prompt + verdict parser

**Files:**
- Modify: `lib/rule_maven/prompts.ex`
- Modify: `lib/rule_maven/llm.ex`
- Test: `test/rule_maven/llm_parse_defects_test.exs` (add a sibling test file instead — see below)
- Test: `test/rule_maven/llm_grounding_critic_test.exs` (new)

**Interfaces:**
- Consumes: none new.
- Produces: `RuleMaven.Prompts.template("grounding_critic")` (registry entry); `RuleMaven.LLM.parse_grounding_verdict(text :: String.t()) :: %{verdict: :grounded | :hallucinated, flagged_clause: String.t() | nil}`.

- [ ] **Step 1: Write the failing tests**

Create `test/rule_maven/llm_grounding_critic_test.exs`:

```elixir
defmodule RuleMaven.LLMGroundingCriticTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  test "parses a grounded verdict with no flagged clause" do
    assert LLM.parse_grounding_verdict("VERDICT: grounded") ==
             %{verdict: :grounded, flagged_clause: nil}
  end

  test "parses a hallucinated verdict with its flagged clause" do
    text = """
    VERDICT: hallucinated
    FLAGGED: Defeating a Monster lowers Terror Level.
    """

    assert LLM.parse_grounding_verdict(text) ==
             %{verdict: :hallucinated, flagged_clause: "Defeating a Monster lowers Terror Level."}
  end

  test "verdict is case/spacing tolerant" do
    assert %{verdict: :hallucinated} =
             LLM.parse_grounding_verdict("verdict:  Hallucinated\nFLAGGED: extra claim")
  end

  test "missing or unparsable verdict falls back to grounded (critic never blocks)" do
    assert %{verdict: :grounded, flagged_clause: nil} = LLM.parse_grounding_verdict("")
    assert %{verdict: :grounded, flagged_clause: nil} = LLM.parse_grounding_verdict("garbage reply")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/llm_grounding_critic_test.exs`
Expected: FAIL — `LLM.parse_grounding_verdict/1 is undefined`

- [ ] **Step 3: Add the prompt template**

In `lib/rule_maven/prompts.ex`, add a new module attribute right after `@cleanup_critic` (before `# Vars: game_name, exclude, rulebook` / `@suggest_questions`):

```elixir
  @grounding_critic """
  You are an adversarial fact-checker. You are given a RULEBOOK QUOTE that was
  cited as support for an ANSWER a rules-assistant wrote. Assume the ANSWER
  contains an unsupported claim until proven otherwise.

  Check: does every claim in the ANSWER follow directly from the QUOTE (or a
  plain logical restatement of it)? A claim the QUOTE does not state or imply
  — even if it sounds plausible for this kind of game — is unsupported.

  First output exactly one verdict line:

  VERDICT: grounded | hallucinated

  - grounded — every claim in the ANSWER is stated or directly implied by the QUOTE.
  - hallucinated — the ANSWER states a rule, effect, or condition the QUOTE does
    not support.

  If hallucinated, output one more line:

  FLAGGED: <the exact unsupported clause, quoted from the ANSWER>

  If grounded, output nothing further.
  """
```

Then add its registry entry to `@specs`, right after the `cleanup_critic` entry:

```elixir
    %{
      key: "grounding_critic",
      group: "Q&A",
      label: "Answer — grounding critic",
      description:
        "Escalated check run only when the cheap heuristic flags an answer as possibly unsupported by its own citation. Typed verdict (grounded/hallucinated) plus the flagged clause.",
      vars: [],
      default: @grounding_critic
    },
```

- [ ] **Step 4: Add `parse_grounding_verdict/1` to `lib/rule_maven/llm.ex`**

Add right after `parse_critic_verdict/1` (after its closing `end`, before the `@doc "Sends a generic chat prompt..."` / `def chat` section):

```elixir
  @grounding_verdicts [:grounded, :hallucinated]
  def grounding_verdicts, do: @grounding_verdicts

  @doc """
  Parses a `grounding_critic` reply: a `VERDICT: grounded | hallucinated` line,
  plus (only on hallucinated) a `FLAGGED: <clause>` line naming the unsupported
  claim. A missing or unrecognized verdict falls back to `:grounded` — this
  critic must never block an answer on a malformed reply.
  """
  def parse_grounding_verdict(text) do
    trimmed = String.trim(text || "")

    verdict =
      case Regex.run(~r/^\s*verdict:\s*(grounded|hallucinated)\b/im, trimmed) do
        [_, v] -> String.to_existing_atom(String.downcase(v))
        _ -> :grounded
      end

    flagged_clause =
      case Regex.run(~r/^\s*flagged:\s*(.+)$/im, trimmed) do
        [_, clause] -> String.trim(clause)
        _ -> nil
      end

    %{verdict: verdict, flagged_clause: flagged_clause}
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_grounding_critic_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/prompts.ex lib/rule_maven/llm.ex test/rule_maven/llm_grounding_critic_test.exs
git commit -m "feat: add grounding_critic prompt + verdict parser"
```

---

### Task 3: `LLM.critique_grounding/3` critic call wrapper

**Files:**
- Modify: `lib/rule_maven/llm.ex`
- Test: `test/rule_maven/llm_grounding_critic_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.LLM.parse_grounding_verdict/1` (Task 2), `RuleMaven.Prompts.template/1`, `model(:cheap)` (existing, `llm.ex:1237`), `chat/3` (existing, `llm.ex:727`).
- Produces: `RuleMaven.LLM.critique_grounding(quotes :: [String.t()], answer :: String.t(), opts :: keyword()) :: {:ok, %{verdict: :grounded | :hallucinated, flagged_clause: String.t() | nil}} | {:error, term()}`. `opts` accepts `:model`, `:game_id`, `:user_id` (all optional).

- [ ] **Step 1: Write the failing test**

Append to `test/rule_maven/llm_grounding_critic_test.exs`:

```elixir
  test "critique_grounding returns the parsed verdict map" do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Monster defeats lower Terror."}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :hallucinated, flagged_clause: "Monster defeats lower Terror."}} =
             LLM.critique_grounding(["Move the Terror Marker up one space."], "some answer")
  end

  test "critique_grounding passes through an error" do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, "boom"} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:error, "boom"} = LLM.critique_grounding(["a quote"], "an answer")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/llm_grounding_critic_test.exs`
Expected: FAIL — `LLM.critique_grounding/2 is undefined` (arity 2 since `opts` defaults)

- [ ] **Step 3: Implement `critique_grounding/3`**

In `lib/rule_maven/llm.ex`, add right after `critique_cleanup/2` (after its closing `end`, before `defp min_kept_ratio`):

```elixir
  @doc """
  Escalated check for whether `answer`'s claims are supported by its own
  cited `quotes`. Only called when `Citations.suspicious?/2` has already
  flagged the pair — this is the expensive (LLM) half of that two-stage
  gate. Uses the cheap model by default (text-only, cheap), same as the
  cleanup critic. Callers treat an error as grounded — a critic failure
  must never block or discard an answer.
  """
  def critique_grounding(quotes, answer, opts \\ []) do
    quoted_text = quotes |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join("\n\n")

    user =
      "CITED QUOTE(S):\n\n" <> quoted_text <> "\n\n---\n\nANSWER:\n\n" <> (answer || "")

    case chat(user, "grounding_critic",
           system: RuleMaven.Prompts.template("grounding_critic"),
           max_tokens: 300,
           model: opts[:model] || model(:cheap),
           operation: "grounding_critic",
           game_id: opts[:game_id],
           user_id: opts[:user_id]
         ) do
      {:ok, text} -> {:ok, parse_grounding_verdict(text)}
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_grounding_critic_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_grounding_critic_test.exs
git commit -m "feat: add LLM.critique_grounding/3 critic call"
```

---

### Task 4: Wire heuristic + critic + single re-ask into `call_llm/8`

**Files:**
- Modify: `lib/rule_maven/llm.ex:209-268` (the `call_llm/8` function)
- Test: `test/rule_maven/llm_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Games.Citations.suspicious?/2` (Task 1), `RuleMaven.LLM.critique_grounding/3` (Task 3).
- Produces: no new public interface — `call_llm/8`'s existing return shape (`{:ok, %{answer:, cited_passage:, ...}}` / `{:error, reason}`) is unchanged; only the `answer`/`citations`/`verdict`/etc. values it can return are affected internally.

- [ ] **Step 1: Write the failing tests**

Append a new `describe` block to `test/rule_maven/llm_test.exs` (before the final `end` of the file — check the file's last few lines first to place it correctly inside the outer `describe`/module but outside any other `describe` block):

```elixir
  describe "grounding critic on fresh answers" do
    setup do
      {:ok, game} = Games.create_game(%{name: "GroundingGame"})
      %{game: game}
    end

    test "a grounded answer is untouched (heuristic never trips)", %{game: game} do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer: "You draw three cards.",
           citations: [%{"quote" => "Each player draws three cards.", "page" => 1, "source" => "Core"}],
           verdict: "info"
         }}
      end)

      {:ok, result} = LLM.ask(game, "How many cards do I draw?", [], [], skip_pool: true)

      assert result.answer == "You draw three cards."
    end

    test "a flagged-but-grounded answer survives the critic (false positive cleared)", %{game: game} do
      # Trips the heuristic on length ratio alone (answer >> quote word count,
      # no trigger keyword needed) — critic then clears it as grounded, so the
      # long-but-faithful paraphrase must survive unchanged.
      long_answer =
        String.duplicate("Draw three cards at the start of your turn as the rulebook describes. ", 10)
        |> String.trim()

      mock_llm(fn body ->
        cond do
          body[:model] == LLM.model(:cheap) ->
            {:ok, %{answer: "VERDICT: grounded"}}

          true ->
            {:ok,
             %{
               answer: long_answer,
               citations: [%{"quote" => "Draw three cards.", "page" => 4, "source" => "Core"}],
               verdict: "info"
             }}
        end
      end)

      {:ok, result} = LLM.ask(game, "How many cards do I draw?", [], [], skip_pool: true)

      assert result.answer == long_answer
    end

    test "a confirmed hallucination triggers one re-ask that succeeds", %{game: game} do
      mock_llm(fn body ->
        cond do
          body[:model] == LLM.model(:cheap) ->
            {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: defeating a Monster lowers Terror."}}

          is_list(body[:messages]) and
              Enum.any?(body[:messages], &String.contains?(&1[:content] || "", "unsupported claim")) ->
            {:ok,
             %{
               answer: "Terror rises when a Hero or Citizen is defeated.",
               citations: [
                 %{"quote" => "Move the Terror Marker up one space.", "page" => 9, "source" => "Core"}
               ],
               verdict: "info"
             }}

          true ->
            {:ok,
             %{
               answer: "Terror rises when a Hero or Citizen is defeated, and lowers when a Monster is defeated.",
               citations: [
                 %{"quote" => "Move the Terror Marker up one space.", "page" => 9, "source" => "Core"}
               ],
               verdict: "info"
             }}
        end
      end)

      {:ok, result} = LLM.ask(game, "What raises Terror?", [], [], skip_pool: true)

      assert result.answer == "Terror rises when a Hero or Citizen is defeated."
    end

    test "a hallucination that survives the retry falls back to refusal", %{game: game} do
      mock_llm(fn body ->
        cond do
          body[:model] == LLM.model(:cheap) ->
            {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: defeating a Monster lowers Terror."}}

          true ->
            {:ok,
             %{
               answer: "Terror rises when a Hero or Citizen is defeated, and lowers when a Monster is defeated.",
               citations: [
                 %{"quote" => "Move the Terror Marker up one space.", "page" => 9, "source" => "Core"}
               ],
               verdict: "info"
             }}
        end
      end)

      {:ok, result} = LLM.ask(game, "What raises Terror?", [], [], skip_pool: true)

      assert result.answer == "The rulebook does not cover this question."
      assert result.citations == []
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs`
Expected: FAIL — the last three new tests fail (asserted answers don't match today's un-checked passthrough); the first new test passes already (nothing to catch).

- [ ] **Step 3: Implement the wiring in `lib/rule_maven/llm.ex`**

Replace the existing `call_llm/8` function body (currently `lib/rule_maven/llm.ex:209-268`) with:

```elixir
  defp call_llm(
         game,
         question,
         expansion_ids,
         recent_context,
         question_embedding,
         cleaned,
         user_id,
         voice
       ) do
    game_ids = [game.id | expansion_ids]
    # Reuse the embedding already computed in ask/5 — no second embed call.
    retrieval_opts = if question_embedding, do: [embedding: question_embedding], else: []
    chunks = RuleMaven.Games.retrieve_chunks_for_games(game_ids, question, retrieval_opts)
    context = build_context_block(chunks, game.id)
    system_prompt = build_system_prompt(game.name, game.category, context, recent_context, voice, game)
    provider_name = provider()
    model_name = model()

    ctx = %{
      question: question,
      model_name: model_name,
      game_id: game.id,
      user_id: user_id
    }

    case request_answer(system_prompt, question, model_name, game.id, user_id) do
      {:ok, llm_result} ->
        llm_result = maybe_reground(llm_result, system_prompt, ctx)

        {:ok,
         %{
           answer: llm_result[:answer],
           cited_passage: llm_result[:cited_passage],
           cited_page: llm_result[:cited_page],
           cited_source: llm_result[:cited_source],
           citations: llm_result[:citations] || [],
           verdict: llm_result[:verdict],
           provider: provider_name,
           model: model_name,
           question_embedding: question_embedding,
           faq_hit: false,
           followups: llm_result[:followups] || [],
           also_asked: llm_result[:also_asked] || [],
           # Canonical question came from the pre-answer normalize step, not the
           # answer JSON — the answer schema no longer carries it.
           cleaned_question: cleaned,
           raw_response: llm_result[:raw_response],
           # Retrieved chunk texts (each prefixed with a [Page N] marker) so the
           # worker can recover the page if the model drops it from the citation.
           source_chunks: Enum.map(chunks, &%{label: &1.label, content: &1.content}),
           styled_answer: llm_result[:styled_answer],
           styled_voice: voice
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Single answer-model call, extracted so `maybe_reground/3`'s retry can
  # re-issue it with a modified system prompt without duplicating the body
  # shape.
  defp request_answer(system_prompt, question, model_name, game_id, user_id) do
    body = %{
      model: model_name,
      max_tokens: 2048,
      response_format: %{type: "json_object"},
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: question}
      ]
    }

    do_request(body, 1, operation: "ask", game_id: game_id, user_id: user_id)
  end

  # Escalate-only-on-suspicion grounding check. Free heuristic first
  # (`Citations.suspicious?/2`); only on a hit does this spend a cheap-model
  # critic call. On a confirmed hallucination, re-runs the full answer call
  # ONCE with a warning naming the flagged claim; a second failure discards
  # the answer in favor of the standard "not covered" refusal so the rest of
  # the pipeline (ask_worker.ex's `refused?/1`) needs no changes.
  defp maybe_reground(llm_result, system_prompt, ctx) do
    quotes = citation_quotes(llm_result[:citations])

    if RuleMaven.Games.Citations.suspicious?(llm_result[:answer], quotes) do
      case critique_grounding(quotes, llm_result[:answer], game_id: ctx.game_id, user_id: ctx.user_id) do
        {:ok, %{verdict: :hallucinated, flagged_clause: clause}} ->
          retry_ungrounded_answer(llm_result, clause, system_prompt, ctx)

        _ ->
          llm_result
      end
    else
      llm_result
    end
  end

  defp retry_ungrounded_answer(original_result, flagged_clause, system_prompt, ctx) do
    warning =
      "\n\nIMPORTANT: a previous answer attempt included this unsupported claim — " <>
        "do not repeat it: #{inspect(flagged_clause)}. Base your answer strictly on the RULEBOOK text above."

    case request_answer(system_prompt <> warning, ctx.question, ctx.model_name, ctx.game_id, ctx.user_id) do
      {:ok, retried_result} ->
        quotes = citation_quotes(retried_result[:citations])

        still_hallucinated? =
          RuleMaven.Games.Citations.suspicious?(retried_result[:answer], quotes) and
            match?(
              {:ok, %{verdict: :hallucinated}},
              critique_grounding(quotes, retried_result[:answer], game_id: ctx.game_id, user_id: ctx.user_id)
            )

        if still_hallucinated? do
          Map.merge(retried_result, %{
            answer: "The rulebook does not cover this question.",
            verdict: "silent",
            citations: [],
            followups: [],
            also_asked: []
          })
        else
          retried_result
        end

      {:error, _reason} ->
        original_result
    end
  end

  defp citation_quotes(citations) when is_list(citations),
    do: citations |> Enum.map(& &1["quote"]) |> Enum.filter(&is_binary/1)

  defp citation_quotes(_citations), do: []
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_test.exs`
Expected: PASS (all tests in the file, old and new)

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "feat: wire grounding critic + single re-ask into call_llm"
```

---

### Task 5: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test 2>&1 | tee /tmp/grounding_critic_full_test.log`
Expected: all tests pass, `0 failures`. (Per project convention, tee to a tmp log rather than re-running; inspect the log if anything fails instead of re-running the whole suite.)

- [ ] **Step 2: Run just the touched files once more in isolation to confirm no shared-state leakage**

Run: `mix test test/rule_maven/citations_test.exs test/rule_maven/llm_grounding_critic_test.exs test/rule_maven/llm_test.exs test/rule_maven/prompts_test.exs`
Expected: all pass.

- [ ] **Step 3: Confirm `mix credo` / `mix format --check-formatted` (if configured) are clean on touched files**

Run: `mix format lib/rule_maven/games/citations.ex lib/rule_maven/prompts.ex lib/rule_maven/llm.ex test/rule_maven/citations_test.exs test/rule_maven/llm_grounding_critic_test.exs test/rule_maven/llm_test.exs`
Expected: exits 0, no diff (or files reformatted — if reformatted, re-run the affected tests once more and commit the formatting).

- [ ] **Step 4: Commit if formatting changed anything**

```bash
git add -A
git commit -m "chore: format grounding critic files" --allow-empty-message -m "no-op if nothing changed"
```

(Skip this commit entirely if `git status` shows no changes after Step 3.)
