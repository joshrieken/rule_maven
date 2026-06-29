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

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :llm_mock)
    end)
  end
end
