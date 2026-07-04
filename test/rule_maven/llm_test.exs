defmodule RuleMaven.LLMTest do
  use RuleMaven.DataCase

  alias RuleMaven.{LLM, Games, Repo}
  alias RuleMaven.Games.QuestionLog

  describe "response parsing" do
    test "extracts answer and citation" do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer: "You move 4 spaces.",
           cited_passage: "You may move up to 4 spaces on your turn.",
           followup: false,
           followups: []
         }}
      end)

      {:ok, game} = Games.create_game(%{name: "Test"})

      {:ok, result} = LLM.ask(game, "How many spaces?")

      assert result.answer =~ "You move 4 spaces"
      assert result.cited_passage =~ "You may move up to 4 spaces"
    end

    test "extracts followup suggestions" do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer: "You move 4.",
           cited_passage: "You may move up to 4 spaces.",
           followup: false,
           followups: ["What if I'm on a road?", "Can I move through walls?"]
         }}
      end)

      {:ok, game} = Games.create_game(%{name: "Test"})

      {:ok, result} = LLM.ask(game, "How many spaces?")

      assert length(result.followups) == 2
      assert "What if I'm on a road?" in result.followups
    end

    test "refusal response passes through correctly" do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer: "The rulebook does not cover this question.",
           cited_passage: "",
           followup: false,
           followups: []
         }}
      end)

      {:ok, game} = Games.create_game(%{name: "Test"})

      {:ok, result} = LLM.ask(game, "Can I trade?")

      assert result.answer =~ "does not cover"
      assert result.followups == []
    end
  end

  describe "decode_answer" do
    test "maps the source field" do
      json = ~s({"answer":"x","citation":"y","page":3,"source":"X errata","verdict":"clear"})
      result = LLM.decode_answer(json)

      assert result[:cited_source] == "X errata"
      assert result[:cited_page] == 3
    end
  end

  describe "system prompt" do
    test "includes refusal instructions" do
      {:ok, game} = Games.create_game(%{name: "Test"})
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt =
          body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)

        Agent.update(agent, fn _ -> prompt end)

        {:ok, %{answer: "ok", cited_passage: "ok", followup: false, followups: []}}
      end)

      LLM.ask(game, "hello")
      prompt = Agent.get(agent, & &1)

      assert prompt =~ "does not cover"
      assert prompt =~ "REFUSAL RULES"
    end

    test "includes recent context when provided" do
      {:ok, game} = Games.create_game(%{name: "Test"})
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt =
          body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)

        Agent.update(agent, fn _ -> prompt end)

        {:ok, %{answer: "ok", cited_passage: "ok", followup: false, followups: []}}
      end)

      LLM.ask(game, "how far?", [], [{"What can I do?", "You can move 4 spaces."}])
      prompt = Agent.get(agent, & &1)

      assert prompt =~ "RECENT CONVERSATION"
      assert prompt =~ "What can I do?"
    end
  end

  describe "pool hit cache" do
    setup do
      {:ok, game} = Games.create_game(%{name: "PoolGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "pool_test",
          email: "pool@test.com",
          password_hash: "x"
        })

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "How many dice do I roll?",
          answer: "You roll 3 six-sided dice.",
          visibility: "community"
        })

      # Update with a fake embedding for similarity match
      Repo.update_all(
        from(ql in QuestionLog, where: ql.id == ^q.id),
        set: [question_embedding: Pgvector.new(Enum.to_list(1..768))]
      )

      %{game: game}
    end

    test "returns pool hit when similar community question exists" do
      {:ok, game} = Games.create_game(%{name: "PoolHitGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "poolhit_test2",
          email: "poolhit2@test.com",
          password_hash: "x"
        })

      # Insert a question with a known embedding
      embedding = Enum.to_list(1..768)

      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Pool question",
        answer: "Pool answer",
        visibility: "community"
      })

      Repo.update_all(
        from(ql in QuestionLog, where: ql.game_id == ^game.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      # Mock the embed to return the same embedding (guarantees cosine_distance ~0)
      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, embedding} end)

      on_exit(fn ->
        Application.delete_env(:rule_maven, :embed_mock)
      end)

      {:ok, result} = LLM.ask(game, "Any question")

      assert result.provider == "pool"
      assert result.model == "cached"
      assert result.answer == "Pool answer"
      assert result[:pool_hit] == true
      assert result[:tier] == :trusted
      assert result[:verified] == true
    end

    test "serves a citation-backed private row as a provisional, anonymized hit" do
      {:ok, game} = Games.create_game(%{name: "ProvisionalGame"})

      author =
        Repo.insert!(%RuleMaven.Users.User{
          username: "prov_author",
          email: "prov@test.com",
          password_hash: "x"
        })

      embedding = Enum.to_list(1..768)

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: author.id,
          question: "What is the author's secret private wording?",
          answer: "Provisional answer.",
          cited_passage: "see p.7",
          cited_page: 7,
          cited_source: "FAQ",
          visibility: "private",
          pooled: true
        })

      Repo.update_all(
        from(ql in QuestionLog, where: ql.id == ^q.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, embedding} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, result} = LLM.ask(game, "different phrasing of the same thing")

      assert result[:pool_hit] == true
      assert result[:tier] == :provisional
      assert result[:verified] == false
      assert result.model == "cached-unverified"
      assert result.answer == "Provisional answer."
      assert result[:source_question_log_id] == q.id
      assert result[:cited_source] == "FAQ"
      # Anonymization: never leak the source row's wording or author.
      refute Map.has_key?(result, :question)
      refute Map.has_key?(result, :user_id)
      refute result.answer =~ "secret private wording"
    end

    test "skip_pool forces a fresh answer past the cache" do
      {:ok, game} = Games.create_game(%{name: "SkipPoolGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "skip_user",
          email: "skip@test.com",
          password_hash: "x"
        })

      embedding = Enum.to_list(1..768)

      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Cached q",
        answer: "Cached answer",
        visibility: "community"
      })

      Repo.update_all(
        from(ql in QuestionLog, where: ql.game_id == ^game.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, embedding} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      mock_llm(fn _body ->
        {:ok, %{answer: "Fresh answer", cited_passage: "p.1", followup: false, followups: []}}
      end)

      {:ok, result} = LLM.ask(game, "Cached q", [], [], skip_pool: true)

      assert result.provider != "pool"
      assert result.answer =~ "Fresh answer"
    end

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
  end

  describe "voice parsing includes loading_phrases" do
    test "parses loading_phrases when present" do
      json = ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald","loading_phrases":["Sounding the horn…","Unrolling the scroll…"]}])
      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == ["Sounding the horn…", "Unrolling the scroll…"]
    end

    test "defaults loading_phrases to [] when missing" do
      json = ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald"}])
      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == []
    end

    test "drops non-string and blank loading_phrases entries" do
      json = ~s([{"slug":"h","label":"H","emoji":"🦉","style":"x","loading_phrases":["ok ", 3, "", "  ", "two"]}])
      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == ["ok", "two"]
    end
  end

  describe "same_user_hit flag" do
    test "false on a cross-user pool hit" do
      {:ok, game} = Games.create_game(%{name: "FlagPoolGame"})

      author =
        Repo.insert!(%RuleMaven.Users.User{
          username: "flag_author",
          email: "fa@test.com",
          password_hash: "x"
        })

      asker =
        Repo.insert!(%RuleMaven.Users.User{
          username: "flag_asker",
          email: "fk@test.com",
          password_hash: "x"
        })

      embedding = Enum.to_list(1..768)

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: author.id,
          question: "How many dice do I roll?",
          answer: "Roll 3 dice.",
          visibility: "community"
        })

      Repo.update_all(from(r in QuestionLog, where: r.id == ^q.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, embedding} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, pool} = LLM.ask(game, "any phrasing", [], [], user_id: asker.id)
      assert pool[:pool_hit] == true
      assert pool[:same_user_hit] == false
    end

    test "true on a same-user hit (no pooled/community row to intercept)" do
      {:ok, game} = Games.create_game(%{name: "FlagOwnGame"})

      asker =
        Repo.insert!(%RuleMaven.Users.User{
          username: "flag_own",
          email: "fo@test.com",
          password_hash: "x"
        })

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, Enum.to_list(1..768)} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, own} =
        Games.log_question(%{
          game_id: game.id,
          user_id: asker.id,
          question: "How many dice do I roll?",
          answer: "Roll 3 dice (mine).",
          cleaned_question: "how many dice do i roll?",
          visibility: "private"
        })

      {:ok, mine} = LLM.ask(game, "How many dice do I roll?", [], [], user_id: asker.id)

      assert mine[:same_user_hit] == true
      assert mine[:source_question_log_id] == own.id
    end

    test "true when the asker repeats their OWN now-pooled question" do
      # Regression: an exact repeat of the asker's own question that has since
      # been pooled/community-shared must still redirect (same_user_hit), not be
      # intercepted by the user-agnostic pool lookup and copied as a new row.
      {:ok, game} = Games.create_game(%{name: "FlagOwnPooledGame"})

      asker =
        Repo.insert!(%RuleMaven.Users.User{
          username: "flag_own_pooled",
          email: "fop@test.com",
          password_hash: "x"
        })

      embedding = Enum.to_list(1..768)

      {:ok, own} =
        Games.log_question(%{
          game_id: game.id,
          user_id: asker.id,
          question: "How many dice do I roll?",
          answer: "Roll 3 dice (mine, pooled).",
          cleaned_question: "how many dice do i roll?",
          visibility: "community"
        })

      Repo.update_all(from(r in QuestionLog, where: r.id == ^own.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, embedding} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, mine} = LLM.ask(game, "How many dice do I roll?", [], [], user_id: asker.id)

      assert mine[:same_user_hit] == true
      assert mine[:source_question_log_id] == own.id
    end
  end

  describe "truncation detection (__truncated__/2)" do
    test "provider finish_reason length/max_tokens is authoritative" do
      assert LLM.__truncated__("length", "anything, even with a period.")
      assert LLM.__truncated__("max_tokens", "anything.")
    end

    test "a complete stop is not truncated regardless of text" do
      refute LLM.__truncated__("stop", "However, tokens")
    end

    test "nil finish_reason falls back to mid-sentence heuristic" do
      assert LLM.__truncated__(nil, "However, tokens")
      refute LLM.__truncated__(nil, "Return the tokens to gain energy.")
      refute LLM.__truncated__(nil, "Spend them wisely!")
      refute LLM.__truncated__(nil, "")
    end
  end

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

  describe "truncation auto-retry" do
    test "retries once with doubled cap and a cache-busting marker" do
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:call, body[:max_tokens], length(body[:messages])})

        if length(body[:messages]) == 1 do
          # First attempt: reasoning ate the whole budget.
          {:ok, %{answer: "", finish_reason: "length"}}
        else
          {:ok, %{answer: "The answer.", finish_reason: "stop"}}
        end
      end)

      assert {:ok, "The answer."} = LLM.chat("What is the rule?", "test", max_tokens: 500)

      assert_received {:call, 500, 1}
      # Retry doubles the cap AND appends a marker message — the LLM proxy
      # caches by messages (ignoring max_tokens), so an unchanged messages
      # array would replay the same truncated response forever.
      assert_received {:call, 1000, 2}
    end

    test "does not retry more than once" do
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, :call)
        {:ok, %{answer: "partial", finish_reason: "length"}}
      end)

      {:ok, "partial"} = LLM.chat("What is the rule?", "test", max_tokens: 500)

      assert_received :call
      assert_received :call
      refute_received :call
    end

    test "reject_truncated still errors when the retry is also truncated" do
      mock_llm(fn _body -> {:ok, %{answer: "partial", finish_reason: "length"}} end)

      assert {:error, :truncated} =
               LLM.chat("What is the rule?", "test", max_tokens: 500, reject_truncated: true)
    end
  end

  describe "normalize cap floor" do
    test "normalize requests a reasoning-safe completion budget" do
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:max_tokens, body[:max_tokens]})
        {:ok, %{answer: "What is the maximum hand size?", finish_reason: "stop"}}
      end)

      {:ok, game} = Games.create_game(%{name: "NormCap Game"})
      LLM.normalize_question(game, "hand size limit", [])

      assert_received {:max_tokens, max_tokens}
      assert max_tokens >= 1024
    end
  end

  describe "suggest_questions/3" do
    test "rejects a truncated response instead of parsing partial output" do
      mock_llm(fn _body -> {:ok, %{answer: "", finish_reason: "length"}} end)

      assert {:error, :truncated} = LLM.suggest_questions("Test Game", "Some rulebook text.")
    end

    test "requests enough completion budget for a reasoning model" do
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:max_tokens, body[:max_tokens]})
        {:ok, %{answer: "CATEGORY: Combat\n- How does combat work?", finish_reason: "stop"}}
      end)

      {:ok, [%{category: "Combat"}]} = LLM.suggest_questions("Test Game", "Some rulebook text.")
      assert_received {:max_tokens, max_tokens}
      assert max_tokens >= 1500
    end
  end

  describe "generate_categories/3" do
    test "rejects a truncated response instead of parsing partial output" do
      # A reasoning model that burns the whole token budget thinking returns
      # empty content with finish_reason "length" — must surface as an error,
      # not {:ok, []} (which the worker would log as a successful 0-category run).
      mock_llm(fn _body -> {:ok, %{answer: "", finish_reason: "length"}} end)

      assert {:error, :truncated} = LLM.generate_categories("Test Game", "Some rulebook text.")
    end

    test "requests enough completion budget for a reasoning model" do
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:max_tokens, body[:max_tokens]})
        {:ok, %{answer: "Combat: fighting rules", finish_reason: "stop"}}
      end)

      {:ok, [%{name: "Combat"}]} = LLM.generate_categories("Test Game", "Some rulebook text.")
      assert_received {:max_tokens, max_tokens}
      assert max_tokens >= 1500
    end
  end

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :llm_mock)
    end)
  end
end
