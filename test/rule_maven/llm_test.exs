defmodule RuleMaven.LLMTest do
  use RuleMaven.DataCase

  alias RuleMaven.{LLM, Games, Repo}
  alias RuleMaven.Games.{Chunk, QuestionLog}

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

    test "parses an optional styled_answer field" do
      json = ~s({"answer":"x","styled_answer":"Arr, x it be."})
      result = LLM.decode_answer(json)

      assert result[:styled_answer] == "Arr, x it be."
    end

    test "styled_answer is nil when the key is absent" do
      json = ~s({"answer":"x"})
      result = LLM.decode_answer(json)

      assert result[:styled_answer] == nil
    end

    test "an info verdict strips a contradictory leading Yes/No" do
      json =
        ~s({"answer":"**Yes** — discarding Items or the Fighter's special action can counter an attack.","verdict":"info"})

      result = LLM.decode_answer(json)

      assert result[:answer] ==
               "Discarding Items or the Fighter's special action can counter an attack."
    end

    test "an info verdict strips a leading No with plain punctuation" do
      json = ~s({"answer":"No, only Items block hits during the Monster Phase.","verdict":"info"})
      result = LLM.decode_answer(json)

      assert result[:answer] == "Only Items block hits during the Monster Phase."
    end

    test "a legal verdict keeps its Yes lead" do
      json = ~s({"answer":"**Yes** — heroes may move through Monsters.","verdict":"legal"})
      result = LLM.decode_answer(json)

      assert result[:answer] == "**Yes** — heroes may move through Monsters."
    end

    test "info answers that merely start with a Yes-prefixed word are untouched" do
      json = ~s({"answer":"Yesterday's errata changed the Terror track.","verdict":"info"})
      result = LLM.decode_answer(json)

      assert result[:answer] == "Yesterday's errata changed the Terror track."
    end

    test "stripping never guts a too-short answer" do
      json = ~s({"answer":"**Yes** — it can.","verdict":"info"})
      result = LLM.decode_answer(json)

      assert result[:answer] == "**Yes** — it can."
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

  describe "persona-direct answer (voice opt)" do
    test "neutral voice (default): system prompt carries no persona instructions, no styled_answer requested" do
      {:ok, game} = Games.create_game(%{name: "Test"})
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt = body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)
        Agent.update(agent, fn _ -> prompt end)
        {:ok, %{answer: "ok", cited_passage: "ok", followup: false, followups: []}}
      end)

      {:ok, result} = LLM.ask(game, "How many spaces?")

      prompt = Agent.get(agent, & &1)
      refute prompt =~ "styled_answer"
      assert result[:styled_answer] == nil
    end

    test "non-neutral voice: system prompt asks for styled_answer in that persona's voice" do
      {:ok, game} = Games.create_game(%{name: "Test"})
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt = body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)
        Agent.update(agent, fn _ -> prompt end)

        {:ok,
         %{
           answer: "You move 4 spaces.",
           styled_answer: "Arr, ye move 4 spaces, matey.",
           cited_passage: "ok",
           followup: false,
           followups: []
         }}
      end)

      {:ok, result} = LLM.ask(game, "How many spaces?", [], [], voice: "pirate")

      prompt = Agent.get(agent, & &1)
      assert prompt =~ "styled_answer"
      assert prompt =~ "pirate quartermaster"
      assert result[:styled_answer] == "Arr, ye move 4 spaces, matey."
      assert result[:styled_voice] == "pirate"
    end

    test "a pool/cache hit never returns styled_answer, even with a voice requested" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      vec = List.duplicate(0.1, 768)

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          question: "How many spaces?",
          answer: "You move 4 spaces.",
          user_id: nil,
          question_embedding: vec,
          citation_valid: true
        })

      Games.mark_pooled(ql)

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, vec} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      # normalize_question/4 runs before the pool check on every ask/5 call and
      # needs a mock too, even though this test expects the pool hit to short
      # -circuit before call_llm/8 ever runs.
      mock_llm(fn _body -> {:ok, %{answer: "How many spaces?"}} end)

      {:ok, result} = LLM.ask(game, "How many spaces?", [], [], voice: "pirate")

      assert result[:pool_hit] == true
      refute Map.has_key?(result, :styled_answer)
    end

    test "a per-game generated voice never gets persona-direct styling — only built-in voices do" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      :ok =
        RuleMaven.Voices.replace_generated(game.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "a courtly herald"}
        ])

      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt = body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)
        Agent.update(agent, fn _ -> prompt end)
        {:ok, %{answer: "ok", cited_passage: "ok", followup: false, followups: []}}
      end)

      {:ok, result} = LLM.ask(game, "some question", [], [], voice: "g:herald")

      prompt = Agent.get(agent, & &1)
      refute prompt =~ "styled_answer"
      refute prompt =~ "courtly herald"
      assert result[:styled_answer] == nil
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

    test "skip_pool appends a unique nonce message so proxy response caches can't replay" do
      {:ok, game} = Games.create_game(%{name: "NonceGame"})
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:llm_body, body})
        {:ok, %{answer: "Fresh answer", cited_passage: "p.1", followups: []}}
      end)

      {:ok, _} = LLM.ask(game, "How many dice?", [], [], skip_pool: true)
      {:ok, _} = LLM.ask(game, "How many dice?", [], [], skip_pool: true)

      nonce_messages =
        collect_llm_bodies()
        |> Enum.flat_map(fn body ->
          Enum.filter(body.messages, fn m ->
            m.role == "system" and m.content =~ "regeneration"
          end)
        end)

      # One nonce message per ask (only on the answer request, not normalize),
      # and the two asks must NOT share the same nonce text — identical text
      # would itself be cached and replayed.
      assert length(nonce_messages) == 2
      assert length(Enum.uniq_by(nonce_messages, & &1.content)) == 2
    end

    test "a plain ask does not carry the regeneration nonce" do
      {:ok, game} = Games.create_game(%{name: "NoNonceGame"})
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:llm_body, body})
        {:ok, %{answer: "Fresh answer", cited_passage: "p.1", followups: []}}
      end)

      {:ok, _} = LLM.ask(game, "How many dice?", [], [])

      assert collect_llm_bodies()
             |> Enum.flat_map(& &1.messages)
             |> Enum.all?(fn m -> not (m.content =~ "regeneration") end)
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
      json =
        ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald","loading_phrases":["Sounding the horn…","Unrolling the scroll…"]}])

      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == ["Sounding the horn…", "Unrolling the scroll…"]
    end

    test "defaults loading_phrases to [] when missing" do
      json = ~s([{"slug":"herald","label":"Herald","emoji":"🦉","style":"a courtly herald"}])
      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == []
    end

    test "drops non-string and blank loading_phrases entries" do
      json =
        ~s([{"slug":"h","label":"H","emoji":"🦉","style":"x","loading_phrases":["ok ", 3, "", "  ", "two"]}])

      [v] = RuleMaven.LLM.__parse_voices__(json)
      assert v.loading_phrases == ["ok", "two"]
    end
  end

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

    test "caps at 12 voices, keeping the 12 lowest (best) ranks" do
      entries =
        for i <- 1..14 do
          ~s({"slug":"v#{i}","label":"V#{i}","emoji":"🙂","style":"x","popularity_rank":#{i}})
        end

      json = "[" <> Enum.join(entries, ",") <> "]"
      result = RuleMaven.LLM.__parse_voices__(json)

      assert length(result) == 12
      assert Enum.map(result, & &1.slug) == for(i <- 1..12, do: "v#{i}")
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

    test "nil finish_reason with strict JSON ending in `}` is not truncated" do
      refute LLM.__truncated__(nil, ~s({"verdict":"matches"}))
    end
  end

  describe "glued interrogative repair (__unglue_interrogative__/1)" do
    test "unglues a leading interrogative stuck to a known second word" do
      assert LLM.__unglue_interrogative__("Whatis abc123?") == "What is abc123?"
      assert LLM.__unglue_interrogative__("Howmany coins?") == "How many coins?"
      assert LLM.__unglue_interrogative__("Cana token move twice?") == "Can a token move twice?"
      assert LLM.__unglue_interrogative__("Whathappens at night?") == "What happens at night?"
    end

    test "never splits real words or valid questions" do
      assert LLM.__unglue_interrogative__("What is the maximum hand size?") ==
               "What is the maximum hand size?"

      assert LLM.__unglue_interrogative__("Whatever happens at night?") ==
               "Whatever happens at night?"

      assert LLM.__unglue_interrogative__("Island tiles: how many?") == "Island tiles: how many?"
      assert LLM.__unglue_interrogative__("Cannon range?") == "Cannon range?"
      assert LLM.__unglue_interrogative__("") == ""
    end

    test "only repairs at the start of the string" do
      assert LLM.__unglue_interrogative__("Explain Whatis") == "Explain Whatis"
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

  describe "normalize_question canonical-form hint" do
    test "the normalize prompt includes existing pooled canonical questions for this game" do
      {:ok, game} = Games.create_game(%{name: "CanonHintGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "canon_hint_user",
          email: "canon_hint@test.com",
          password_hash: "x"
        })

      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "how many players can I do?",
        cleaned_question: "What is the maximum number of players?",
        answer: "5",
        visibility: "private",
        pooled: true
      })

      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:prompt, List.last(body[:messages])[:content]})
        {:ok, %{answer: "What is the maximum number of players?"}}
      end)

      LLM.normalize_question(game, "what is the player count?")

      assert_received {:prompt, prompt}
      assert prompt =~ "What is the maximum number of players?"
    end

    test "no existing questions yet: normalize prompt has no canonical hint block" do
      {:ok, game} = Games.create_game(%{name: "NoCanonHintGame"})
      test_pid = self()

      mock_llm(fn body ->
        send(test_pid, {:prompt, List.last(body[:messages])[:content]})
        {:ok, %{answer: "What is the player count?"}}
      end)

      LLM.normalize_question(game, "how many players?")

      assert_received {:prompt, prompt}
      refute prompt =~ "already-answered"
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
          {:ok, %{answer: "Fresh answer.", cited_passage: "p.1", followup: false, followups: []}}
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

  describe "grounding critic on fresh answers" do
    setup do
      RuleMaven.Settings.put("llm_cheap_model_openrouter", "google/gemini-2.0-flash")
      {:ok, game} = Games.create_game(%{name: "GroundingGame"})
      %{game: game}
    end

    test "a grounded answer is untouched (heuristic never trips)", %{game: game} do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer: "You draw three cards.",
           citations: [
             %{"quote" => "Each player draws three cards.", "page" => 1, "source" => "Core"}
           ],
           verdict: "info"
         }}
      end)

      {:ok, result} = LLM.ask(game, "How many cards do I draw?", [], [], skip_pool: true)

      assert result.answer == "You draw three cards."
    end

    test "a flagged-but-grounded answer survives the critic (false positive cleared)", %{
      game: game
    } do
      # Trips the heuristic on length ratio alone (answer >> quote word count,
      # no trigger keyword needed) — critic then clears it as grounded, so the
      # long-but-faithful paraphrase must survive unchanged.
      long_answer =
        String.duplicate(
          "Draw three cards at the start of your turn as the rulebook describes. ",
          10
        )
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
              Enum.any?(
                body[:messages],
                &String.contains?(&1[:content] || "", "unsupported claim")
              ) ->
            {:ok,
             %{
               answer: "Terror rises when a Hero or Citizen is defeated.",
               citations: [
                 %{
                   "quote" => "Move the Terror Marker up one space.",
                   "page" => 9,
                   "source" => "Core"
                 }
               ],
               verdict: "info"
             }}

          true ->
            {:ok,
             %{
               answer:
                 "Terror rises when a Hero or Citizen is defeated, and lowers when a Monster is defeated.",
               citations: [
                 %{
                   "quote" => "Move the Terror Marker up one space.",
                   "page" => 9,
                   "source" => "Core"
                 }
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
               answer:
                 "Terror rises when a Hero or Citizen is defeated, and lowers when a Monster is defeated.",
               citations: [
                 %{
                   "quote" => "Move the Terror Marker up one space.",
                   "page" => 9,
                   "source" => "Core"
                 }
               ],
               verdict: "info"
             }}
        end
      end)

      {:ok, result} = LLM.ask(game, "What raises Terror?", [], [], skip_pool: true)

      assert result.answer == "The rulebook does not cover this question."
      assert result.citations == []
    end

    test "a refusal after the retry also survives clears the stale scalar citation fields", %{
      game: game
    } do
      # Regression test: retried_result's `cited_passage`/`cited_page`/`cited_source`
      # scalar fields must be cleared alongside `citations: []` in the refusal
      # fallback. If they're left set to the retried (still-hallucinated) answer's
      # real, grounded quote, ask_worker.ex's legacy-wrap path (which reconstructs
      # a synthetic citation from those scalars whenever `citations` comes back
      # empty) re-attaches a "valid" citation to a "not covered" refusal.
      #
      # A real chunk is seeded here — matching the quote the mocked retry cites —
      # so this exercises the same non-trivial retrieval path production hits,
      # rather than the vacuous case where `source_chunks` is empty regardless
      # of whether the bug is fixed.
      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Core rules",
          kind: "rulebook",
          full_text: "seed"
        })

      {:ok, doc} = Games.update_document(doc, %{status: "published"})

      Repo.insert!(%Chunk{
        document_id: doc.id,
        chunk_index: 0,
        content: "[Page 9]\nMove the Terror Marker up one space.",
        page_number: 9,
        embedding: Pgvector.new(List.duplicate(0.1, 768))
      })

      Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      mock_llm(fn body ->
        cond do
          body[:model] == LLM.model(:cheap) ->
            {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: defeating a Monster lowers Terror."}}

          true ->
            {:ok,
             %{
               answer:
                 "Terror rises when a Hero or Citizen is defeated, and lowers when a Monster is defeated.",
               citations: [
                 %{
                   "quote" => "Move the Terror Marker up one space.",
                   "page" => 9,
                   "source" => "Core"
                 }
               ],
               cited_passage: "Move the Terror Marker up one space.",
               cited_page: 9,
               cited_source: "Core",
               verdict: "info"
             }}
        end
      end)

      {:ok, result} = LLM.ask(game, "What raises Terror?", [], [], skip_pool: true)

      assert result.answer == "The rulebook does not cover this question."
      assert result.citations == []
      assert result.cited_passage == nil
      assert result.cited_page == nil
      assert result.cited_source == nil
    end
  end

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :llm_mock)
    end)
  end

  # Drains every {:llm_body, body} message the mock sent to the test process.
  defp collect_llm_bodies(acc \\ []) do
    receive do
      {:llm_body, body} -> collect_llm_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
