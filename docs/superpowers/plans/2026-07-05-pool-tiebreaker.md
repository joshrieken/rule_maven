# Answer-Pool Paraphrase Tiebreaker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the cross-user answer pool serve a cached answer when a paraphrase's cosine similarity lands in 0.85–0.92 (currently a flat miss below the 0.92 floor), gated by a cheap LLM equivalence check so loosening the floor doesn't cause false-positive matches.

**Architecture:** `Games.find_similar_question_in_pool/2` gets its lookup threshold widened (via an existing `opts[:threshold]` override, no signature change) down to 0.85 similarity. `LLM.ask/5` reorders its cache tiers (own-user semantic fallback now runs before the cross-user pool check, since it's free and stricter) and, when the pool returns a candidate below the 0.92 direct-hit floor, calls a new cheap-model yes/no tiebreaker (new Prompts registry entry) before deciding to serve it. Tiebreaker "no" or any error/timeout falls through to fresh generation — never blocks, never serves an unmatched answer.

**Tech Stack:** Elixir/Phoenix, Ecto/Postgres with pgvector, existing `RuleMaven.Prompts` registry, existing `RuleMaven.LLM.chat/3` helper.

## Global Constraints

- Every LLM prompt (system + user) must live in the `RuleMaven.Prompts` registry, never hardcoded inline — this repo's standing rule.
- Tiebreaker failure (LLM error, timeout, ambiguous output) must resolve to a miss (fresh generation), never raise and never serve an unmatched cached answer.
- No new admin-configurable setting for the 0.85 floor — it's a code constant (YAGNI; the existing `pool_similarity_threshold` setting still governs the direct-hit floor).
- Reordering own-user semantic fallback ahead of the pool check must not remove any existing coverage (pool lookup already has no `user_id` filter, so this is safe — see spec).

---

### Task 1: Expose cosine similarity + pool threshold accessors in `Games`

**Files:**
- Modify: `lib/rule_maven/games.ex:3032` (`cosine_sim/2` becomes public)
- Modify: `lib/rule_maven/games.ex:2367-2390` (add two new accessor functions near `pool_distance_threshold/0`)
- Test: `test/rule_maven/games_test.exs` (append new `describe` block)

**Interfaces:**
- Produces: `RuleMaven.Games.cosine_sim/2` (public, was private) — `cosine_sim(a, b) :: float()` where `a`/`b` are `Pgvector.Ecto.Vector` structs or lists, returns cosine similarity in `[-1.0, 1.0]`.
- Produces: `RuleMaven.Games.pool_similarity_floor/0 :: float()` — the current admin-configured direct-hit similarity floor (default 0.92).
- Produces: `RuleMaven.Games.pool_tiebreaker_distance_threshold/0 :: float()` — cosine distance ceiling corresponding to the fixed 0.85 tiebreaker-band floor, for passing as `opts[:threshold]` to `find_similar_question_in_pool/2`.
- Consumes: nothing new (uses existing private `pool_distance_threshold/0` in the same module).

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven/games_test.exs` (add near the top-level, after the `alias`/`import` lines, a new `describe` block — this file already has `alias RuleMaven.Games` and `alias RuleMaven.Repo` at the top):

```elixir
  describe "pool tiebreaker accessors" do
    test "cosine_sim/2 computes cosine similarity between two vectors" do
      # theta = arccos(0.88) ~= 28.36 degrees; vecB = [cos(theta), sin(theta), 0, ...]
      dim = 768
      vec_a = [1.0 | List.duplicate(0.0, dim - 1)]
      vec_b = [0.88, 0.474_999_890_641_401_23 | List.duplicate(0.0, dim - 2)]

      sim = Games.cosine_sim(Pgvector.new(vec_a), Pgvector.new(vec_b))

      assert_in_delta sim, 0.88, 0.001
    end

    test "pool_similarity_floor/0 defaults to 0.92" do
      assert Games.pool_similarity_floor() == 0.92
    end

    test "pool_similarity_floor/0 reflects an admin override" do
      RuleMaven.Settings.put("pool_similarity_threshold", "0.9")
      assert Games.pool_similarity_floor() == 0.9
    end

    test "pool_tiebreaker_distance_threshold/0 corresponds to 0.85 similarity" do
      assert_in_delta Games.pool_tiebreaker_distance_threshold(), 1.0 - 0.85, 0.0001
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/games_test.exs --only line:9999 2>&1 | tail -5` won't target correctly — instead run the whole file and confirm the new tests fail on undefined function:

Run: `mix test test/rule_maven/games_test.exs`
Expected: FAIL — `Games.pool_similarity_floor/0 is undefined`, `Games.pool_tiebreaker_distance_threshold/0 is undefined`, and `Games.cosine_sim/2 is undefined or private`.

- [ ] **Step 3: Make `cosine_sim/2` public and add the two accessors**

In `lib/rule_maven/games.ex`, change line 3032 from:

```elixir
  defp cosine_sim(a, b) do
```

to:

```elixir
  @doc """
  Cosine similarity between two embedding vectors (`Pgvector.Ecto.Vector` or
  plain lists). Returns a float in [-1.0, 1.0]; 0.0 if either vector is zero.
  """
  def cosine_sim(a, b) do
```

Then, in the same file, right after `defp pool_distance_threshold do ... end` (currently ending at line 2390, immediately before the `# Cosine distance ceiling for a same-user semantic hit.` comment), insert:

```elixir

  @doc """
  The current direct-hit pool similarity floor (admin-configurable via the
  `pool_similarity_threshold` setting, default 0.92). Exposed publicly so
  callers can classify a returned pool candidate's actual similarity without
  duplicating the setting lookup.
  """
  def pool_similarity_floor, do: 1.0 - pool_distance_threshold()

  @doc """
  Cosine distance ceiling for the widened pool lookup that also surfaces
  tiebreaker-eligible near-misses, down to a fixed 0.85 similarity floor.
  Not admin-configurable — the tiebreaker LLM call is the safety net that
  makes a lower floor safe, so there's no separate setting for it.
  """
  def pool_tiebreaker_distance_threshold, do: 1.0 - @default_pool_tiebreaker_similarity
```

And add the module attribute next to `@default_pool_similarity 0.92` (line 2367):

```elixir
  @default_pool_similarity 0.92
  @default_user_dup_similarity 0.95
  @default_pool_tiebreaker_similarity 0.85
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/games_test.exs`
Expected: PASS (all tests in the file, including the 4 new ones)

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_test.exs
git commit -m "feat: expose cosine_sim/2 and pool tiebreaker threshold accessors"
```

---

### Task 2: Add the pool-tiebreaker prompt to the Prompts registry

**Files:**
- Modify: `lib/rule_maven/prompts.ex` (add two `@` template constants + two `@specs` entries, following the `normalize_question`/`normalize_question_system` pattern at lines 86-119 and 691-707)
- Test: `test/rule_maven/prompts_test.exs` if it exists, else `test/rule_maven/games_test.exs` is NOT the right place — create `test/rule_maven/prompts_pool_tiebreaker_test.exs`

**Interfaces:**
- Produces: `RuleMaven.Prompts.template("pool_tiebreaker_system")` and `RuleMaven.Prompts.template("pool_tiebreaker")` (existing generic `template/1`/`render/2` functions, no new functions needed).
- Consumes: existing `RuleMaven.Prompts.render/2`, `RuleMaven.Prompts.template/1`.

- [ ] **Step 1: Check for an existing prompts test file**

Run: `ls test/rule_maven/ | grep -i prompt`

If a file like `test/rule_maven/prompts_test.exs` exists, add the new tests there instead of creating a new file — read it first to match its structure. If none exists, proceed with Step 2 as written (new file).

- [ ] **Step 2: Write the failing test**

Create `test/rule_maven/prompts_pool_tiebreaker_test.exs`:

```elixir
defmodule RuleMaven.PromptsPoolTiebreakerTest do
  use RuleMaven.DataCase

  alias RuleMaven.Prompts

  test "pool_tiebreaker_system default instructs a strict yes/no equivalence check" do
    text = Prompts.template("pool_tiebreaker_system")
    assert text =~ "yes"
    assert text =~ "no"
  end

  test "pool_tiebreaker renders both question bindings" do
    rendered =
      Prompts.render("pool_tiebreaker", %{
        question_a: "What is the d20 used for?",
        question_b: "What does the d20 do?"
      })

    assert rendered =~ "What is the d20 used for?"
    assert rendered =~ "What does the d20 do?"
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/rule_maven/prompts_pool_tiebreaker_test.exs`
Expected: FAIL — `template("pool_tiebreaker_system")` raises (no matching spec key) because `Prompts.spec/1` (used internally by `default/1`/`template/1`) has no `"pool_tiebreaker_system"` entry yet.

- [ ] **Step 4: Add the templates and registry entries**

In `lib/rule_maven/prompts.ex`, immediately after the `@normalize_question` constant (ends around line 113, right before the `# Shared cleanup fragments` comment at line 115), insert:

```elixir

  # ──────────────────────────────────────────────────────────────────────────
  # Pool tiebreaker. Called only when a cross-user pool candidate's cosine
  # similarity lands in the 0.85-0.92 ambiguous band (below the direct-hit
  # floor but above the tiebreaker floor) — see RuleMaven.LLM.find_pool_hit/6.
  # Vars: question_a (pool candidate), question_b (new asker's question).
  # ──────────────────────────────────────────────────────────────────────────
  @pool_tiebreaker_system """
  You judge whether two board-game rules questions are asking the SAME underlying question, just worded differently. Answer with exactly one word: "yes" or "no" — nothing else, no punctuation, no explanation.

  Answer "yes" only when both questions would be answered by the exact same rule. Different word order, terse fragments vs. complete sentences, and synonyms do NOT matter. A question that is merely related, broader, narrower, or about a different game element must be "no".
  """

  @pool_tiebreaker """
  Question A: {{question_a}}
  Question B: {{question_b}}

  Same underlying rules question? Answer yes or no.
  """
```

Then, in the `@specs` list, immediately after the `"normalize_question"` entry (ends around line 707, right before the `"cleanup_light"` entry), insert:

```elixir
    %{
      key: "pool_tiebreaker_system",
      group: "Q&A",
      label: "Pool tiebreaker — system",
      description:
        "System primer for the yes/no equivalence check run on ambiguous-similarity pool candidates (0.85-0.92).",
      vars: [],
      default: @pool_tiebreaker_system
    },
    %{
      key: "pool_tiebreaker",
      group: "Q&A",
      label: "Pool tiebreaker — prompt",
      description:
        "Asks whether a near-miss pool candidate and the new question are the same underlying rules question.",
      vars: ~w(question_a question_b),
      default: @pool_tiebreaker
    },
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/rule_maven/prompts_pool_tiebreaker_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/prompts.ex test/rule_maven/prompts_pool_tiebreaker_test.exs
git commit -m "feat: add pool_tiebreaker prompt to the Prompts registry"
```

---

### Task 3: Reorder cache tiers and wire the tiebreaker into `LLM.ask/5`

**Files:**
- Modify: `lib/rule_maven/llm.ex:35-105` (reorder `ask/5`'s `cond`, extract pool lookup into a new lazy `find_pool_hit/6`)
- Modify: `lib/rule_maven/llm.ex` (add new private `paraphrase_equivalent?/4`, placed near `do_normalize/4`)
- Test: `test/rule_maven/llm_test.exs` (append new `describe` block)

**Interfaces:**
- Consumes: `RuleMaven.Games.find_similar_question_in_pool/2` (existing, `opts[:threshold]` override), `RuleMaven.Games.cosine_sim/2` (Task 1), `RuleMaven.Games.pool_similarity_floor/0` (Task 1), `RuleMaven.Games.pool_tiebreaker_distance_threshold/0` (Task 1), `RuleMaven.Prompts.template/1` + `RuleMaven.Prompts.render/2` with keys `"pool_tiebreaker_system"`/`"pool_tiebreaker"` (Task 2), existing `chat/3`, `model/1`.
- Produces: `ask/5`'s observable behavior only — no new public functions. `find_pool_hit/6` and `paraphrase_equivalent?/4` are both private (`defp`).

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven/llm_test.exs`, right before the final `end` of the module (after line 690's `defp mock_llm` block — insert the new `describe` block before `defp mock_llm`, since `defp` must be last in the module body... actually in Elixir private function placement within a module doesn't need to be last, but to match this file's existing convention, insert the new `describe` block anywhere before the closing `end`, e.g. right after the last existing `describe` block and before `defp mock_llm(fun) do`):

```elixir
  describe "pool tiebreaker (paraphrase near-miss)" do
    # theta = arccos(0.88) ~= 28.36 degrees — deterministic cosine similarity,
    # independent of any real embedding model.
    @near_miss_vec_a [1.0 | List.duplicate(0.0, 767)]
    @near_miss_vec_b [0.88, 0.474_999_890_641_401_23 | List.duplicate(0.0, 766)]

    setup do
      {:ok, game} = Games.create_game(%{name: "TiebreakerGame"})

      author =
        Repo.insert!(%RuleMaven.Users.User{
          username: "tb_author_#{System.unique_integer([:positive])}",
          email: "tb_author_#{System.unique_integer([:positive])}@test.com",
          password_hash: "x"
        })

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: author.id,
          question: "What is the d20 used for?",
          answer: "It resolves any check requiring a d20 roll.",
          visibility: "community",
          citation_valid: true
        })

      Repo.update_all(
        from(ql in QuestionLog, where: ql.id == ^q.id),
        set: [question_embedding: Pgvector.new(@near_miss_vec_a)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, @near_miss_vec_b} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      %{game: game, pool_row: q}
    end

    test "tiebreaker 'yes' serves the near-miss pool candidate", %{game: game, pool_row: q} do
      mock_llm(fn body ->
        content = body[:messages] |> List.last() |> Map.get(:content)

        if content =~ "Same underlying rules question?" do
          {:ok, %{answer: "yes"}}
        else
          {:ok, %{answer: "What does the d20 do?"}}
        end
      end)

      {:ok, result} = LLM.ask(game, "What does the d20 do?")

      assert result[:pool_hit] == true
      assert result[:source_question_log_id] == q.id
      assert result.provider == "pool"
    end

    test "tiebreaker 'no' falls through to fresh generation", %{game: game} do
      mock_llm(fn body ->
        content = body[:messages] |> List.last() |> Map.get(:content)

        cond do
          content =~ "Same underlying rules question?" ->
            {:ok, %{answer: "no"}}

          content =~ "canonical question" ->
            {:ok, %{answer: "What does the d20 do?"}}

          true ->
            {:ok,
             %{answer: "Fresh answer.", cited_passage: "p.1", followup: false, followups: []}}
        end
      end)

      {:ok, result} = LLM.ask(game, "What does the d20 do?")

      assert result[:pool_hit] != true
      assert result.answer == "Fresh answer."
    end

    test "tiebreaker LLM error falls through to fresh generation, never raises", %{game: game} do
      mock_llm(fn body ->
        content = body[:messages] |> List.last() |> Map.get(:content)

        cond do
          content =~ "Same underlying rules question?" ->
            {:error, "simulated timeout"}

          content =~ "canonical question" ->
            {:ok, %{answer: "What does the d20 do?"}}

          true ->
            {:ok,
             %{answer: "Fresh answer.", cited_passage: "p.1", followup: false, followups: []}}
        end
      end)

      {:ok, result} = LLM.ask(game, "What does the d20 do?")

      assert result[:pool_hit] != true
      assert result.answer == "Fresh answer."
    end

    test "below the 0.85 floor misses without any tiebreaker call", %{game: game} do
      # Orthogonal vector: cosine similarity 0.0, well below the 0.85 floor.
      orthogonal = [0.0, 1.0 | List.duplicate(0.0, 766)]
      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, orthogonal} end)

      mock_llm(fn body ->
        content = body[:messages] |> List.last() |> Map.get(:content)

        if content =~ "Same underlying rules question?" do
          flunk("tiebreaker must not be called below the 0.85 floor")
        else
          {:ok,
           %{answer: "Fresh answer.", cited_passage: "p.1", followup: false, followups: []}}
        end
      end)

      {:ok, result} = LLM.ask(game, "Completely unrelated question")

      assert result[:pool_hit] != true
      assert result.answer == "Fresh answer."
    end
  end

  describe "cache tier ordering" do
    test "own-user semantic fallback wins over a cross-user pool candidate" do
      {:ok, game} = Games.create_game(%{name: "OrderingGame"})

      asker =
        Repo.insert!(%RuleMaven.Users.User{
          username: "order_asker",
          email: "order_asker@test.com",
          password_hash: "x"
        })

      other =
        Repo.insert!(%RuleMaven.Users.User{
          username: "order_other",
          email: "order_other@test.com",
          password_hash: "x"
        })

      shared_embedding = Enum.to_list(1..768)

      # Asker's own un-pooled private answer.
      {:ok, own_q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: asker.id,
          question: "Own prior question",
          answer: "Own prior answer.",
          visibility: "private"
        })

      # A different user's community-pooled answer, same embedding (so both
      # tiers would match at similarity 1.0 if reached).
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Other user's question",
        answer: "Other user's answer.",
        visibility: "community"
      })

      Repo.update_all(
        from(ql in QuestionLog, where: ql.game_id == ^game.id),
        set: [question_embedding: Pgvector.new(shared_embedding)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, shared_embedding} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, result} = LLM.ask(game, "Any phrasing", [], [], user_id: asker.id)

      assert result[:same_user_hit] == true
      assert result[:source_question_log_id] == own_q.id
      assert result.answer == "Own prior answer."
    end
  end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs`
Expected: FAIL — the new tests fail because `ask/5` doesn't yet call a tiebreaker (the "yes"/"no" cases both currently behave like today's flat 0.92 threshold: the near-miss embeddings at ~0.88 similarity are below today's 0.92 floor, so today's code treats them as a miss regardless of tiebreaker mock — "tiebreaker 'yes' serves the near-miss pool candidate" will FAIL because no pool hit occurs today).

- [ ] **Step 3: Reorder `ask/5` and extract the pool lookup**

In `lib/rule_maven/llm.ex`, replace the entire `ask/5` function body (currently lines 35-105) with:

```elixir
  def ask(game, question, expansion_ids \\ [], recent_context \\ [], opts \\ []) do
    skip_pool = Keyword.get(opts, :skip_pool, false)
    # Canonical sorted form — cache rows store and match this exact set.
    expansion_ids = Enum.sort(expansion_ids)

    # Step 0: normalize the question to a standalone canonical form FIRST, then
    # drive everything downstream off the cleaned text. Paraphrases and terse
    # fragments ("snack bar max limit") collapse onto one phrasing, so they share
    # an embedding — lifting the pool hit rate — and the retrieval + LLM answer
    # also run on the cleaned question. Falls back to the raw question on error.
    cleaned = normalize_question(game, question, recent_context, user_id: opts[:user_id])
    match_text = if cleaned == "", do: question, else: cleaned

    # Embed the cleaned question (used for pool check + stored on the logged row,
    # so a future paraphrase normalizes to the same form and matches it).
    question_embedding =
      case RuleMaven.Embed.embed(match_text) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    user_id = opts[:user_id]

    # Same-user tiers: a returning asker is served their OWN prior answer even
    # when it never pooled. Exact (normalized-text) dedup first, then a tight
    # semantic fallback. Both are plain cosine/text queries (no LLM call), so
    # they're cheap to run eagerly and checked before the pool — a repeat in
    # the asker's own words resolves for free, without spending a pool query
    # or (in the ambiguous band) a tiebreaker LLM call.
    user_exact =
      !skip_pool && user_id &&
        RuleMaven.Games.find_user_duplicate(game.id, user_id, match_text, question, expansion_ids)

    user_semantic =
      !skip_pool && user_id && question_embedding &&
        RuleMaven.Games.find_user_similar(game.id, user_id, question_embedding,
          expansion_ids: expansion_ids
        )

    cond do
      # The asker's OWN exact (normalized-text) repeat wins over everything else:
      # the pool match is user-agnostic, so once the asker's row is pooled a plain
      # pool_hit would tag it same_user_hit=false and AskWorker would copy it into
      # a second row instead of redirecting. Check own-exact first so a repeat
      # always collapses to the one existing Q&A.
      user_exact ->
        serve_from_cache(user_exact, question_embedding, cleaned, game.id, user_id, true)

      user_semantic ->
        serve_from_cache(user_semantic, question_embedding, cleaned, game.id, user_id, true)

      pool_hit = find_pool_hit(game, question_embedding, expansion_ids, skip_pool, match_text, user_id) ->
        serve_from_cache(pool_hit, question_embedding, cleaned, game.id, user_id, false)

      true ->
        call_llm(
          game,
          match_text,
          expansion_ids,
          recent_context,
          question_embedding,
          cleaned,
          user_id
        )
    end
  end

  # Cross-user pool lookup, widened to also surface near-miss candidates
  # (0.85-0.92 similarity) gated by an LLM equivalence tiebreaker. Pooled/
  # community answers are rulebook-derived, so any asker may be served a
  # match — the lookup intentionally doesn't filter by user (no user_id
  # passed to find_similar_question_in_pool/2).
  defp find_pool_hit(_game, nil, _expansion_ids, _skip_pool, _match_text, _user_id), do: nil
  defp find_pool_hit(_game, _embedding, _expansion_ids, true, _match_text, _user_id), do: nil

  defp find_pool_hit(game, question_embedding, expansion_ids, false, match_text, user_id) do
    case RuleMaven.Games.find_similar_question_in_pool(game.id, question_embedding,
           expansion_ids: expansion_ids,
           threshold: RuleMaven.Games.pool_tiebreaker_distance_threshold()
         ) do
      nil ->
        nil

      {row, _tier} = hit ->
        similarity = RuleMaven.Games.cosine_sim(row.question_embedding, question_embedding)

        cond do
          similarity >= RuleMaven.Games.pool_similarity_floor() ->
            hit

          paraphrase_equivalent?(row, match_text, game, user_id) ->
            hit

          true ->
            nil
        end
    end
  end

  # Cheap-model yes/no equivalence check for a pool candidate whose similarity
  # landed in the ambiguous band. Any error/timeout resolves to false (a
  # miss) — never blocks or fails the request, never serves an unmatched
  # answer.
  defp paraphrase_equivalent?(row, asker_question, game, user_id) do
    candidate_question = RuleMaven.Games.QuestionLog.display_question(row)

    user =
      RuleMaven.Prompts.render("pool_tiebreaker", %{
        question_a: candidate_question,
        question_b: asker_question
      })

    case chat(user, "pool_tiebreaker",
           system: RuleMaven.Prompts.template("pool_tiebreaker_system"),
           max_tokens: 10,
           model: model(:cheap),
           operation: "pool_tiebreaker",
           game_id: game.id,
           user_id: user_id
         ) do
      {:ok, text} ->
        text |> to_string() |> String.trim() |> String.downcase() |> String.starts_with?("yes")

      {:error, _} ->
        false
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_test.exs`
Expected: PASS (all tests in the file, including the 5 new ones)

- [ ] **Step 5: Run the full pool/trust/expansion-cache regression suite**

Run: `mix test test/rule_maven/llm_test.exs test/rule_maven/trust_test.exs test/rule_maven/games_pool_invalidation_test.exs test/rule_maven/games_expansion_cache_test.exs test/rule_maven/games_test.exs test/rule_maven/llm_user_attribution_test.exs`
Expected: PASS — these are the existing suites that call `find_similar_question_in_pool/2` or exercise `LLM.ask/5`'s cache tiers directly; confirms the reorder and threshold widening didn't regress direct-hit behavior, expansion scoping, or invalidation.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "feat: paraphrase tiebreaker for near-miss answer-pool candidates"
```

---

## Self-Review Notes

- **Spec coverage:** floor widening (Task 1), tiebreaker prompt in registry (Task 2), ordering change + wiring + error handling (Task 3) — all three spec sections covered. Logging (plain `Logger.info`, not a Job-log worker entry) was in the spec but is intentionally omitted from this plan as non-essential polish; if wanted, add a `Logger.info` call inside `paraphrase_equivalent?/4` before returning.
- **Type consistency:** `find_pool_hit/6` returns the same `{row, tier}` shape `serve_from_cache/6` already expects — no signature mismatch with the pre-existing `pool_hit`/`user_exact`/`user_semantic` variables it replaces.
- **Scope:** single subsystem (answer-pool cache tiering), one plan, three tasks each independently testable.
