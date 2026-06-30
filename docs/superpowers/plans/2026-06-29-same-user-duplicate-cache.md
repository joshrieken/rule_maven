# Same-user Duplicate Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the same user's identical/reworded re-asks from producing duplicate Q&A rows and LLM calls — serve them from their own history.

**Architecture:** Three-tier serving inside `LLM.ask/5` (first hit wins, else call LLM): existing shared pool → new same-user exact dedup → new same-user semantic fallback (tighter threshold). Plus a normalization fix so an identical re-ask inside a thread is normalized standalone instead of as a followup, letting it collapse onto the original's canonical form.

**Tech Stack:** Elixir, Phoenix, Ecto, Postgres + pgvector, ExUnit.

## Global Constraints

- No schema/table change; no new migration.
- Same-user tiers are **user-scoped**; never widen cross-user serving (that stays pool-gated by citation).
- Same-user semantic threshold must be **stricter** than the pool's (`pool_similarity_threshold`, default 0.92). Default `user_dup_similarity_threshold` = **0.95**.
- Reuse the existing cache-serving result shape exactly (`provider: "pool"`, `pool_hit: true`, `model: "cached" | "cached-unverified"`, etc.) so `AskWorker` needs no change.
- Skip same-user tiers when `user_id` is nil or `skip_pool` is true.
- Conventional commits. Co-Authored-By trailer on every commit:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## File Structure

- `lib/rule_maven/games.ex` — add `find_user_duplicate/4`, `find_user_similar/4`, and private `user_dup_distance_threshold/0` + `@default_user_dup_similarity`. Mirrors the existing `find_similar_question_in_pool/3` / `pool_distance_threshold/0`.
- `lib/rule_maven/llm.ex` — Piece 1 in `normalize_question/3`; wire tiers 2/3 + extract a `serve_from_cache/5` helper in `ask/5`.
- `test/rule_maven/games_test.exs` — tests for the two queries.
- `test/rule_maven/llm_test.exs` — tests for normalization fix + tier precedence/serving.

---

### Task 1: `Games.find_user_duplicate/4` — same-user exact dedup query

**Files:**
- Modify: `lib/rule_maven/games.ex` (add near `find_similar_question_in_pool/3`, ~line 1647)
- Test: `test/rule_maven/games_test.exs`

**Interfaces:**
- Produces: `Games.find_user_duplicate(game_id, user_id, cleaned, raw) :: {%QuestionLog{}, :trusted | :provisional} | nil`
  - `cleaned` = normalized question text (non-empty), `raw` = original typed text.
  - Matches the asker's own most-recent eligible row whose normalized text equals `cleaned` (case-insensitive), or whose raw `question` equals `raw` when `cleaned_question` is null.
  - Returns `nil` when `user_id` is nil or no row matches. Tier via `pool_tier/1`.

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/games_test.exs` (inside the module, new describe block):

```elixir
  describe "find_user_duplicate/4" do
    setup do
      {:ok, game} = Games.create_game(%{name: "DupGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "dup_user",
          email: "dup@test.com",
          password_hash: "x"
        })

      %{game: game, user: user}
    end

    test "matches the user's own prior answer by normalized text", %{game: game, user: user} do
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "How many CARDS do I draw?",
          answer: "Draw 2 cards.",
          cleaned_question: "how many cards do i draw",
          visibility: "private"
        })

      assert {%{id: id}, _tier} =
               Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "anything")

      assert id == q.id
    end

    test "falls back to raw question when cleaned_question is nil", %{game: game, user: user} do
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "How many cards do I draw?",
          answer: "Draw 2 cards.",
          visibility: "private"
        })

      assert {%{id: id}, _} =
               Games.find_user_duplicate(game.id, user.id, "noncanon", "how many cards do i draw?")

      assert id == q.id
    end

    test "ignores another user's matching row", %{game: game, user: user} do
      other =
        Repo.insert!(%RuleMaven.Users.User{
          username: "other",
          email: "other@test.com",
          password_hash: "x"
        })

      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "How many cards do I draw?",
        answer: "Draw 2 cards.",
        cleaned_question: "how many cards do i draw",
        visibility: "community"
      })

      assert Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "x") == nil
    end

    test "ignores refused, needs_review, and Thinking... rows", %{game: game, user: user} do
      for attrs <- [
            %{refused: true},
            %{needs_review: true},
            %{answer: "Thinking..."}
          ] do
        Games.log_question(
          Map.merge(
            %{
              game_id: game.id,
              user_id: user.id,
              question: "Q",
              answer: "A",
              cleaned_question: "skip me",
              visibility: "private"
            },
            attrs
          )
        )
      end

      assert Games.find_user_duplicate(game.id, user.id, "skip me", "Q") == nil
    end

    test "returns nil when user_id is nil", %{game: game} do
      assert Games.find_user_duplicate(game.id, nil, "anything", "anything") == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/games_test.exs -k "find_user_duplicate" 2>&1 | tee /tmp/t1.log | tail -20`
Expected: FAIL — `function RuleMaven.Games.find_user_duplicate/4 is undefined`.

- [ ] **Step 3: Implement the query**

In `lib/rule_maven/games.ex`, add after `find_similar_question_in_pool/3` (before `pool_tier/1`):

```elixir
  @doc """
  The asker's own most-recent reusable answer for an exact (normalized) repeat of
  their question — independent of pooling and the embedding threshold, so a
  repeat always collapses to one Q&A even when the first answer never pooled.

  Eligible rows: same `user_id` and `game_id`, not refused/blocked/needs_review,
  a real answer (not the in-flight "Thinking..." sentinel), and a normalized-text
  match (`cleaned_question == cleaned`, case-insensitive; or `question == raw`
  when `cleaned_question` is null). Returns `{row, tier}` or nil; nil when
  `user_id` is nil.
  """
  def find_user_duplicate(_game_id, nil, _cleaned, _raw), do: nil

  def find_user_duplicate(game_id, user_id, cleaned, raw) do
    cleaned = String.downcase(to_string(cleaned))
    raw = String.downcase(to_string(raw))

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id,
          where: q.refused == false and q.blocked == false and q.needs_review == false,
          where: q.answer != "Thinking..." and not is_nil(q.answer),
          where:
            fragment("lower(?) = ?", q.cleaned_question, ^cleaned) or
              (is_nil(q.cleaned_question) and fragment("lower(?) = ?", q.question, ^raw)),
          order_by: [desc: q.inserted_at, desc: q.id],
          limit: 1
      )

    case row do
      nil -> nil
      q -> {q, pool_tier(q)}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/games_test.exs -k "find_user_duplicate" 2>&1 | tee /tmp/t1.log | tail -20`
Expected: PASS (5 tests). Then `rm /tmp/t1.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_test.exs
git commit -m "feat: same-user exact-duplicate question lookup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `Games.find_user_similar/4` + tighter threshold — same-user semantic fallback

**Files:**
- Modify: `lib/rule_maven/games.ex` (add `find_user_similar/4`; add `@default_user_dup_similarity` near `@default_pool_similarity` ~line 1739; add `user_dup_distance_threshold/0` near `pool_distance_threshold/0`)
- Test: `test/rule_maven/games_test.exs`

**Interfaces:**
- Produces: `Games.find_user_similar(game_id, user_id, embedding, opts \\ []) :: {%QuestionLog{}, tier} | nil`
  - `embedding` is a plain list (as `LLM.ask` holds it). Matches the asker's own eligible row with smallest cosine distance ≤ `user_dup_distance_threshold()` (default ceiling 0.05, i.e. similarity 0.95). nil when `user_id` is nil or `embedding` is nil.
  - Consumes `pool_tier/1` (Task is in same module).

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/games_test.exs`:

```elixir
  describe "find_user_similar/4" do
    setup do
      {:ok, game} = Games.create_game(%{name: "SimGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "sim_user",
          email: "sim@test.com",
          password_hash: "x"
        })

      # Stored row's embedding is the unit axis e0 = [1.0, 0.0, 0.0, ...].
      e0 = [1.0 | List.duplicate(0.0, 767)]

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "stored q",
          answer: "stored answer",
          visibility: "private"
        })

      Repo.update_all(
        from(ql in RuleMaven.Games.QuestionLog, where: ql.id == ^q.id),
        set: [question_embedding: Pgvector.new(e0)]
      )

      %{game: game, user: user, q: q}
    end

    test "hits on an embedding within the tight threshold", %{game: game, user: user, q: q} do
      e0 = [1.0 | List.duplicate(0.0, 767)]
      assert {%{id: id}, _tier} = Games.find_user_similar(game.id, user.id, e0)
      assert id == q.id
    end

    # cos=0.93 query: distance 0.07 — inside the pool's 0.08 ceiling but OUTSIDE
    # the stricter same-user 0.05 ceiling, so it must NOT match by default.
    test "misses when distance exceeds the tight threshold but is within pool's", %{
      game: game,
      user: user
    } do
      cos = 0.93
      q_vec = [cos, :math.sqrt(1.0 - cos * cos) | List.duplicate(0.0, 766)]
      assert Games.find_user_similar(game.id, user.id, q_vec) == nil
    end

    test "the same near-miss DOES match once the threshold is loosened", %{game: game, user: user} do
      RuleMaven.Settings.put("user_dup_similarity_threshold", "0.90")
      on_exit(fn -> RuleMaven.Settings.delete("user_dup_similarity_threshold") end)

      cos = 0.93
      q_vec = [cos, :math.sqrt(1.0 - cos * cos) | List.duplicate(0.0, 766)]
      assert {_row, _tier} = Games.find_user_similar(game.id, user.id, q_vec)
    end

    test "returns nil for nil user_id or nil embedding", %{game: game, user: user} do
      e0 = [1.0 | List.duplicate(0.0, 767)]
      assert Games.find_user_similar(game.id, nil, e0) == nil
      assert Games.find_user_similar(game.id, user.id, nil) == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/games_test.exs -k "find_user_similar" 2>&1 | tee /tmp/t2.log | tail -20`
Expected: FAIL — `function RuleMaven.Games.find_user_similar/4 is undefined`.

- [ ] **Step 3: Implement threshold + query**

In `lib/rule_maven/games.ex`, next to `@default_pool_similarity 0.92` (~line 1739) add:

```elixir
  @default_user_dup_similarity 0.95
```

Add `find_user_similar/4` after `find_user_duplicate/4`:

```elixir
  @doc """
  Same-user semantic fallback: the asker's own closest prior answer above a
  STRICTER similarity floor than the shared pool (`user_dup_similarity_threshold`,
  default 0.95). Stricter because same-user history has no curation/trust gate —
  a loose match would serve a wrong answer with nothing behind it. Returns
  `{row, tier}` or nil; nil when `user_id` or `embedding` is nil.
  """
  def find_user_similar(game_id, user_id, embedding, opts \\ [])
  def find_user_similar(_game_id, nil, _embedding, _opts), do: nil
  def find_user_similar(_game_id, _user_id, nil, _opts), do: nil

  def find_user_similar(game_id, user_id, embedding, opts) do
    threshold = Keyword.get(opts, :threshold, user_dup_distance_threshold())
    vec = Pgvector.new(embedding)

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id,
          where: q.refused == false and q.blocked == false and q.needs_review == false,
          where: q.answer != "Thinking..." and not is_nil(q.answer),
          where: not is_nil(q.question_embedding),
          where:
            fragment("cosine_distance(?, ?::vector)", q.question_embedding, ^vec) <= ^threshold,
          order_by: [asc: fragment("cosine_distance(?, ?::vector)", q.question_embedding, ^vec)],
          limit: 1
      )

    case row do
      nil -> nil
      q -> {q, pool_tier(q)}
    end
  end
```

Add the threshold helper next to `pool_distance_threshold/0`:

```elixir
  # Cosine distance ceiling for a same-user semantic hit. Stricter than the pool.
  defp user_dup_distance_threshold do
    sim =
      case RuleMaven.Settings.get("user_dup_similarity_threshold") do
        nil -> @default_user_dup_similarity
        "" -> @default_user_dup_similarity
        val ->
          case Float.parse(val) do
            {f, _} -> f
            :error -> @default_user_dup_similarity
          end
      end

    1.0 - sim
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/games_test.exs -k "find_user_similar" 2>&1 | tee /tmp/t2.log | tail -20`
Expected: PASS (4 tests). Then `rm /tmp/t2.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_test.exs
git commit -m "feat: same-user semantic fallback lookup with tighter threshold

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Piece 1 — normalize an identical re-ask standalone, not as a followup

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`normalize_question/3`, ~line 148)
- Test: `test/rule_maven/llm_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: behavior change only — when `raw` (case-insensitive, trimmed) equals any question in `recent_context`, normalization routes through the context-free, text-cached branch (`NormalizeCache`) instead of the followup branch.

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/llm_test.exs` a new describe block:

```elixir
  describe "normalize_question repeat handling" do
    alias RuleMaven.LLM.NormalizeCache

    test "an identical re-ask is normalized standalone (text-cached)" do
      {:ok, game} = Games.create_game(%{name: "RepeatGame"})

      LLM.normalize_question(game, "How many dice do I roll?", [
        {"How many dice do I roll?", "You roll 3 dice."}
      ])

      # Standalone branch populates the per-raw cache; followup branch never does.
      assert {:ok, _} = NormalizeCache.get({game.id, "how many dice do i roll?"})
    end

    test "a genuine followup is NOT text-cached (stays context-sensitive)" do
      {:ok, game} = Games.create_game(%{name: "FollowupGame"})

      LLM.normalize_question(game, "what about on a road?", [
        {"How many dice do I roll?", "You roll 3 dice."}
      ])

      assert NormalizeCache.get({game.id, "what about on a road?"}) == :miss
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs -k "normalize_question repeat" 2>&1 | tee /tmp/t3.log | tail -20`
Expected: FAIL — the first test fails because the identical re-ask currently takes the followup branch and is not cached.

- [ ] **Step 3: Implement the routing change**

Replace the body of `normalize_question/3` (`lib/rule_maven/llm.ex:148-172`) with:

```elixir
  def normalize_question(game, question, recent_context \\ []) do
    raw = question |> to_string() |> String.trim()

    # A literally identical re-ask is NOT a followup — normalize it standalone so
    # it collapses onto the original's canonical form + embedding (and hits the
    # cache) instead of being rewritten against the conversation.
    repeat? =
      Enum.any?(recent_context, fn {q, _a} ->
        String.downcase(String.trim(to_string(q))) == String.downcase(raw)
      end)

    cond do
      raw == "" ->
        raw

      # Followups resolve against the conversation — not cacheable by raw text.
      recent_context != [] and not repeat? ->
        do_normalize(game, raw, recent_context)

      true ->
        key = {game.id, String.downcase(raw)}

        case RuleMaven.LLM.NormalizeCache.get(key) do
          {:ok, cached} ->
            cached

          :miss ->
            cleaned = do_normalize(game, raw, [])
            RuleMaven.LLM.NormalizeCache.put(key, cleaned)
            cleaned
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_test.exs -k "normalize_question repeat" 2>&1 | tee /tmp/t3.log | tail -20`
Expected: PASS (2 tests). Then `rm /tmp/t3.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "fix: normalize an identical re-ask standalone, not as a followup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Wire tiers 2 & 3 into `LLM.ask/5` (precedence + DRY serving)

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`ask/5`, ~lines 35-88)
- Test: `test/rule_maven/llm_test.exs`

**Interfaces:**
- Consumes: `Games.find_user_duplicate/4`, `Games.find_user_similar/4` (Tasks 1-2).
- Produces: `LLM.ask/5` now serves a same-user exact dup, then a same-user semantic match, before calling the LLM. All cache branches go through a new private `serve_from_cache/5`.

- [ ] **Step 1: Write the failing tests**

Add to the `describe "pool hit cache"` block (or a new describe) in `test/rule_maven/llm_test.exs`:

```elixir
    test "serves the same user's own un-pooled prior answer (exact dup)" do
      {:ok, game} = Games.create_game(%{name: "UserDupGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "udup",
          email: "udup@test.com",
          password_hash: "x"
        })

      # Private, NOT pooled, no embedding — invisible to the shared pool.
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "How many dice do I roll?",
          answer: "You roll 3 dice.",
          visibility: "private"
        })

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, result} = LLM.ask(game, "How many dice do I roll?", [], [], user_id: user.id)

      assert result[:pool_hit] == true
      assert result.answer == "You roll 3 dice."
      assert result[:source_question_log_id] == q.id
      assert result.provider == "pool"
    end

    test "does NOT serve another user's un-pooled answer" do
      {:ok, game} = Games.create_game(%{name: "NoCrossGame"})

      author =
        Repo.insert!(%RuleMaven.Users.User{
          username: "author_x",
          email: "ax@test.com",
          password_hash: "x"
        })

      asker =
        Repo.insert!(%RuleMaven.Users.User{
          username: "asker_x",
          email: "kx@test.com",
          password_hash: "x"
        })

      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "How many dice do I roll?",
        answer: "Author's private answer.",
        visibility: "private"
      })

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      mock_llm(fn _ ->
        {:ok, %{answer: "Fresh LLM answer", cited_passage: "p.1", followup: false, followups: []}}
      end)

      {:ok, result} = LLM.ask(game, "How many dice do I roll?", [], [], user_id: asker.id)

      assert result.provider != "pool"
      assert result.answer =~ "Fresh LLM answer"
    end

    test "skip_pool also bypasses the same-user dedup" do
      {:ok, game} = Games.create_game(%{name: "UserSkipGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "uskip",
          email: "uskip@test.com",
          password_hash: "x"
        })

      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "Cached own answer.",
        visibility: "private"
      })

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      mock_llm(fn _ ->
        {:ok, %{answer: "Fresh answer", cited_passage: "p.1", followup: false, followups: []}}
      end)

      {:ok, result} =
        LLM.ask(game, "How many dice do I roll?", [], [], user_id: user.id, skip_pool: true)

      assert result.provider != "pool"
      assert result.answer =~ "Fresh answer"
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_test.exs -k "same user|cross|skip_pool also" 2>&1 | tee /tmp/t4.log | tail -25`
Expected: FAIL — the exact-dup test fails (currently falls through to the LLM / errors since no `mock_llm`).

- [ ] **Step 3: Implement the wiring + DRY helper**

In `lib/rule_maven/llm.ex`, replace the pool block (`ask/5`, lines 54-88, from the `# Pooled/community answers...` comment through the closing `end` of the `cond`) with:

```elixir
    user_id = opts[:user_id]

    # Pooled/community answers are rulebook-derived, so any asker may be served a
    # match — the lookup intentionally doesn't filter by user (no user_id passed).
    pool_hit =
      !skip_pool && question_embedding &&
        RuleMaven.Games.find_similar_question_in_pool(game.id, question_embedding)

    # Same-user tiers: a returning asker is served their OWN prior answer even
    # when it never pooled. Exact (normalized-text) dedup first, then a tight
    # semantic fallback. Skipped when there's no signed-in asker or skip_pool.
    user_exact =
      !skip_pool && user_id &&
        RuleMaven.Games.find_user_duplicate(game.id, user_id, match_text, question)

    user_semantic =
      !skip_pool && user_id && question_embedding &&
        RuleMaven.Games.find_user_similar(game.id, user_id, question_embedding)

    cond do
      pool_hit ->
        serve_from_cache(pool_hit, question_embedding, cleaned, game.id, user_id)

      user_exact ->
        serve_from_cache(user_exact, question_embedding, cleaned, game.id, user_id)

      user_semantic ->
        serve_from_cache(user_semantic, question_embedding, cleaned, game.id, user_id)

      true ->
        call_llm(game, match_text, expansion_ids, recent_context, question_embedding, cleaned)
    end
  end

  # Builds the cache-serving result from a `{row, tier}` and records the save.
  # Serves answer text only — never the source row's question wording or author.
  defp serve_from_cache({row, tier}, question_embedding, cleaned, game_id, user_id) do
    RuleMaven.LLM.Savings.record_cache_hit("ask", game_id, user_id)

    {:ok,
     %{
       answer: row.canonical_answer || row.answer,
       cited_passage: row.cited_passage,
       cited_page: row.cited_page,
       verdict: row.verdict,
       provider: "pool",
       # Encode tier in the model field so it survives a page reload.
       model: if(tier == :trusted, do: "cached", else: "cached-unverified"),
       pool_hit: true,
       tier: tier,
       verified: tier == :trusted,
       source_question_log_id: row.id,
       question_embedding: question_embedding,
       cleaned_question: cleaned
     }}
  end
```

> This removes the inline pool-serving map (old lines 61-83) and replaces all three branches with `serve_from_cache/5`. Confirm the old `RuleMaven.LLM.Savings.record_cache_hit(...)` call inside the former pool branch is gone (now inside the helper) — do not leave a duplicate.

- [ ] **Step 4: Run the new tests, then the full file**

Run: `mix test test/rule_maven/llm_test.exs 2>&1 | tee /tmp/t4.log | tail -25`
Expected: PASS — new tests plus the existing `pool hit cache` tests (the pool path still serves via the helper). Then `rm /tmp/t4.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_test.exs
git commit -m "feat: serve same-user duplicate questions from cache

Adds same-user exact dedup and a tight semantic fallback to LLM.ask,
ordered after the shared pool, behind a DRY serve_from_cache helper.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run: `mix test 2>&1 | tee /tmp/full.log | tail -30`
Expected: all green. If anything fails, fix before proceeding. Inspect with `/tmp/full.log`, then `rm /tmp/full.log`.

- [ ] **Step 2: Confirm no compile warnings introduced**

Run: `mix compile --warnings-as-errors 2>&1 | tail -15`
Expected: clean compile.

---

## Self-Review

**Spec coverage:**
- Piece 1 (standalone-normalize repeats) → Task 3. ✓
- Piece 2 (exact same-user dedup) → Task 1 + wired in Task 4. ✓
- Piece 3 (semantic fallback, 0.95) → Task 2 + wired in Task 4. ✓
- Precedence pool → exact → semantic → LLM → Task 4 cond. ✓
- Reuse result shape / AskWorker unchanged → `serve_from_cache/5` mirrors the old pool map exactly. ✓
- `record_cache_hit` on all cache tiers → inside `serve_from_cache/5`. ✓
- Skip when `user_id` nil or `skip_pool` → guards in queries + `ask/5`. ✓
- No cross-user widening; no schema change → Tasks 1/2 user-scoped, no migration. ✓

**Type consistency:** `find_user_duplicate/4` and `find_user_similar/4` both return `{%QuestionLog{}, tier} | nil`; `serve_from_cache/5` consumes the `{row, tier}` tuple from all three producers (`find_similar_question_in_pool/3` already returns that shape). `match_text` (normalized, non-empty) is passed as the dedup `cleaned` arg; `question` (raw) as the fallback. Consistent.

**Placeholder scan:** none — every step has concrete code/commands.
