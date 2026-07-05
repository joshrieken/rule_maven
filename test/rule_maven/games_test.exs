defmodule RuleMaven.GamesTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games
  alias RuleMaven.Repo
  import RuleMaven.GamesFixtures

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

  describe "games" do
    alias RuleMaven.Games.Game

    import RuleMaven.GamesFixtures

    @invalid_attrs %{name: nil, bgg_id: nil}

    test "list_games/0 returns all games" do
      game = game_fixture()
      assert Games.list_games() == [game]
    end

    test "get_game!/1 returns the game with given id" do
      game = game_fixture()
      assert Games.get_game!(game.id) == game
    end

    test "create_game/1 with valid data creates a game" do
      valid_attrs = %{name: "some name", bgg_id: 42}

      assert {:ok, %Game{} = game} = Games.create_game(valid_attrs)
      assert game.name == "some name"
      assert game.bgg_id == 42
    end

    test "create_game/1 persists weight" do
      valid_attrs = %{name: "some name", bgg_id: 42, weight: 2.6667}

      assert {:ok, %Game{} = game} = Games.create_game(valid_attrs)
      assert_in_delta game.weight, 2.6667, 0.0001
    end

    test "create_game/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Games.create_game(@invalid_attrs)
    end

    test "update_game/2 with valid data updates the game" do
      game = game_fixture()
      update_attrs = %{name: "some updated name", bgg_id: 43}

      assert {:ok, %Game{} = game} = Games.update_game(game, update_attrs)
      assert game.name == "some updated name"
      assert game.bgg_id == 43
    end

    test "update_game/2 with invalid data returns error changeset" do
      game = game_fixture()
      assert {:error, %Ecto.Changeset{}} = Games.update_game(game, @invalid_attrs)
      assert game == Games.get_game!(game.id)
    end

    test "delete_game/1 deletes the game" do
      game = game_fixture()
      assert {:ok, %Game{}} = Games.delete_game(game)
      assert_raise Ecto.NoResultsError, fn -> Games.get_game!(game.id) end
    end

    test "change_game/1 returns a game changeset" do
      game = game_fixture()
      assert %Ecto.Changeset{} = Games.change_game(game)
    end
  end

  describe "delete_game/1 cleans up via delete_document/1 (not a bare Repo.delete_all)" do
    defp doc_with_file(game) do
      pdf_path = "rulebooks/delgame_#{System.unique_integer([:positive])}.pdf"
      full = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "pdf")

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "alpha\fbeta",
          pdf_path: pdf_path
        })

      {doc, full}
    end

    test "removes stored source files and clears generation-state settings" do
      game =
        game_fixture(%{
          name: "DelGame #{System.unique_integer([:positive])}",
          bgg_id: System.unique_integer([:positive])
        })
      {_doc, full} = doc_with_file(game)
      RuleMaven.Settings.put("cheat_content_#{game.id}", "stale")

      assert File.exists?(full)

      assert {:ok, %RuleMaven.Games.Game{}} = Games.delete_game(game)

      refute File.exists?(full)
      assert RuleMaven.Settings.get("cheat_content_#{game.id}") == nil
      assert_raise Ecto.NoResultsError, fn -> Games.get_game!(game.id) end
    end
  end

  describe "delete_all_games/0 cleans up via delete_document/1" do
    test "removes stored source files for every game" do
      game1 =
        game_fixture(%{
          name: "Bulk1 #{System.unique_integer([:positive])}",
          bgg_id: System.unique_integer([:positive])
        })

      game2 =
        game_fixture(%{
          name: "Bulk2 #{System.unique_integer([:positive])}",
          bgg_id: System.unique_integer([:positive])
        })

      pdf_path1 = "rulebooks/bulk1_#{System.unique_integer([:positive])}.pdf"
      full1 = Application.app_dir(:rule_maven, "priv/static/#{pdf_path1}")
      File.mkdir_p!(Path.dirname(full1))
      File.write!(full1, "pdf")

      pdf_path2 = "rulebooks/bulk2_#{System.unique_integer([:positive])}.pdf"
      full2 = Application.app_dir(:rule_maven, "priv/static/#{pdf_path2}")
      File.mkdir_p!(Path.dirname(full2))
      File.write!(full2, "pdf")

      {:ok, _} =
        Games.create_document(%{
          game_id: game1.id,
          label: "R1",
          full_text: "alpha\fbeta",
          pdf_path: pdf_path1
        })

      {:ok, _} =
        Games.create_document(%{
          game_id: game2.id,
          label: "R2",
          full_text: "alpha\fbeta",
          pdf_path: pdf_path2
        })

      assert File.exists?(full1)
      assert File.exists?(full2)

      {count, _} = Games.delete_all_games()
      assert count >= 2

      refute File.exists?(full1)
      refute File.exists?(full2)
    end
  end

  describe "grouped questions" do
    setup do
      game = game_fixture()

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "test_grouped",
          email: "test_grouped@test.com",
          password_hash: "x"
        })

      %{game: game, user: user}
    end

    test "grouped_questions/1 keeps each question self-contained (no nesting)", %{
      game: game,
      user: user
    } do
      _q1 = log_question!(game.id, user.id, "Root Q", "Root A")
      _q2 = log_question!(game.id, user.id, "Followup Q", "Followup A")

      grouped = Games.grouped_questions(game)
      assert length(grouped) == 2
      assert Enum.all?(grouped, &(&1.followups == []))
    end

    test "grouped_questions/1 groups same text into history", %{game: game, user: user} do
      q1 = log_question!(game.id, user.id, "Same question", "Answer v1")
      q2 = log_question!(game.id, user.id, "Same question", "Answer v2")

      grouped = Games.grouped_questions(game)
      assert length(grouped) == 1

      group = hd(grouped)
      assert group.primary.id == q2.id
      assert length(group.history) == 1
      assert hd(group.history).id == q1.id
    end

    test "grouped_questions/1 handles roots with no followups or history", %{
      game: game,
      user: user
    } do
      log_question!(game.id, user.id, "Lone question", "Lone answer")

      grouped = Games.grouped_questions(game)
      assert length(grouped) == 1

      group = hd(grouped)
      assert group.followups == []
      assert group.history == []
    end

    test "grouped_questions/1 returns empty list when no questions exist", %{game: game} do
      assert Games.grouped_questions(game) == []
    end

    test "grouped_questions/2 returns every user's questions when no user_id filter is given",
         %{game: game, user: user} do
      other =
        Repo.insert!(%RuleMaven.Users.User{
          username: "test_grouped_other",
          email: "test_grouped_other@test.com",
          password_hash: "x"
        })

      log_question!(game.id, user.id, "Mine", "Mine answer")
      log_question!(game.id, other.id, "Theirs", "Theirs answer")

      grouped = Games.grouped_questions(game)
      questions = Enum.map(grouped, & &1.primary.question)

      assert "Mine" in questions
      assert "Theirs" in questions
    end

    test "grouped_questions/2 preloads :user on the primary row", %{game: game, user: user} do
      log_question!(game.id, user.id, "Who asked?", "Someone")

      grouped = Games.grouped_questions(game)
      assert hd(grouped).primary.user.id == user.id
      assert hd(grouped).primary.user.username == user.username
    end

    test "grouped_questions/2 with limit: nil does not cap results", %{game: game, user: user} do
      for i <- 1..250 do
        log_question!(game.id, user.id, "Q#{i}", "A#{i}")
      end

      grouped = Games.grouped_questions(game, limit: nil)
      assert length(grouped) == 250
    end

    test "grouped_questions/2 default limit still caps at 200", %{game: game, user: user} do
      for i <- 1..205 do
        log_question!(game.id, user.id, "Cap Q#{i}", "A#{i}")
      end

      grouped = Games.grouped_questions(game, user_id: user.id)
      assert length(grouped) == 200
    end
  end

  describe "community pool" do
    setup do
      game = game_fixture()

      user1 =
        Repo.insert!(%RuleMaven.Users.User{
          username: "comm_user1",
          email: "comm1@test.com",
          password_hash: "x"
        })

      user2 =
        Repo.insert!(%RuleMaven.Users.User{
          username: "comm_user2",
          email: "comm2@test.com",
          password_hash: "x"
        })

      %{game: game, user1: user1, user2: user2}
    end

    test "community_questions/2 returns FAQ-approved questions", %{
      game: game,
      user1: user1,
      user2: user2
    } do
      _q1 = log_question!(game.id, user1.id, "Community Q", "Community A", nil, "community")
      _q2 = log_question!(game.id, user2.id, "Another Q", "Another A", nil, "community")

      community = Games.community_questions(game)
      assert length(community) == 2
    end

    test "community_questions/2 excludes non-FAQ questions", %{game: game, user1: user1} do
      _q1 = log_question!(game.id, user1.id, "Public Q", "Public A", nil, "community")
      log_question!(game.id, user1.id, "Private Q", "Private A", nil, "private")

      community = Games.community_questions(game)
      assert length(community) == 1
      assert hd(community).question == "Public Q"
    end

    test "community_questions/2 excludes given user's questions", %{
      game: game,
      user1: user1,
      user2: user2
    } do
      _q1 = log_question!(game.id, user1.id, "User1 Q", "A1", nil, "community")
      _q2 = log_question!(game.id, user2.id, "User2 Q", "A2", nil, "community")

      # Exclude user1 — should only see user2's question
      community = Games.community_questions(game, user1.id)
      assert length(community) == 1
      assert hd(community).question == "User2 Q"
    end

    test "community_questions/2 returns all community questions", %{game: game, user1: user1} do
      _q1 = log_question!(game.id, user1.id, "First Q", "A1", nil, "community")
      _q2 = log_question!(game.id, user1.id, "Second Q", "A2", nil, "community")

      community = Games.community_questions(game)
      assert length(community) == 2
    end

    test "log_question/1 defaults to private visibility", %{game: game, user1: user1} do
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user1.id,
          question: "Default visibility?",
          answer: "Should be private"
        })

      assert q.visibility == "private"
    end

    test "log_question/1 respects explicit visibility", %{game: game, user1: user1} do
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user1.id,
          question: "Explicit community",
          answer: "Visible",
          visibility: "community"
        })

      assert q.visibility == "community"
    end
  end

  describe "search" do
    setup do
      game = game_fixture()

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "search_user",
          email: "search@test.com",
          password_hash: "x"
        })

      log_question!(game.id, user.id, "How many cards?", "Five.")
      log_question!(game.id, user.id, "Can I move twice?", "No.")
      log_question!(game.id, user.id, "What about trading?", "Only on your turn.")

      %{game: game}
    end

    test "search_questions/2 finds matching questions", %{game: game} do
      results = Games.search_questions(game, "cards")
      assert length(results) == 1
      assert hd(results).question == "How many cards?"
    end

    test "search_questions/2 matches partial text", %{game: game} do
      results = Games.search_questions(game, "move")
      assert length(results) == 1
      assert hd(results).question == "Can I move twice?"
    end

    test "search_questions/2 returns empty for no match", %{game: game} do
      results = Games.search_questions(game, "zzznotfound")
      assert results == []
    end

    test "search_questions/2 is case insensitive", %{game: game} do
      results = Games.search_questions(game, "TRADING")
      assert length(results) == 1
      assert hd(results).question == "What about trading?"
    end

    test "search_questions/2 treats a literal % in the query as a literal character, not a wildcard",
         %{game: game} do
      # An unescaped "%" would match zero-or-more of anything, so "50%" would
      # incorrectly match unrelated rows too (any text containing "50").
      results = Games.search_questions(game, "50%")
      assert results == []
    end

    test "search_questions/2 treats a literal _ in the query as a literal character, not a single-char wildcard",
         %{game: game} do
      # An unescaped "_" matches any single character, so "c_rds" would
      # incorrectly match "cards".
      results = Games.search_questions(game, "c_rds")
      assert results == []
    end

    test "search_questions/2 still matches when the query contains a literal % that's actually present" do
      game2 = game_fixture(%{bgg_id: System.unique_integer([:positive])})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "search_user2",
          email: "search2@test.com",
          password_hash: "x"
        })

      log_question!(game2.id, user.id, "Do I get a 50% bonus?", "Yes.")

      results = Games.search_questions(game2, "50%")
      assert length(results) == 1
      assert hd(results).question == "Do I get a 50% bonus?"
    end
  end

  defp log_question!(
         game_id,
         user_id,
         question,
         answer,
         parent_id \\ nil,
         visibility \\ "community"
       ) do
    {:ok, q} =
      Games.log_question(%{
        game_id: game_id,
        user_id: user_id,
        question: question,
        answer: answer,
        parent_question_id: parent_id,
        visibility: visibility
      })

    q
  end

  describe "update_canonical/3 (curated FAQ text)" do
    setup do
      game = game_fixture()
      q = log_question!(game.id, nil, "How many cards?", "Draw five.")
      %{q: q}
    end

    test "sets canonical question and answer", %{q: q} do
      {:ok, updated} =
        Games.update_canonical(q, "How many cards do I draw?", "You draw five cards.")

      assert updated.canonical_question == "How many cards do I draw?"
      assert updated.canonical_answer == "You draw five cards."
    end

    test "blank strings clear back to nil", %{q: q} do
      {:ok, set} = Games.update_canonical(q, "Q", "A")
      assert set.canonical_question == "Q"

      {:ok, cleared} = Games.update_canonical(set, "  ", "")
      assert cleared.canonical_question == nil
      assert cleared.canonical_answer == nil
    end
  end

  describe "DMCA takedowns" do
    test "take_down_game/3 records the takedown and restore clears it" do
      game = game_fixture()
      refute Games.taken_down?(game)

      {:ok, down} = Games.take_down_game(game, "copyright claim", "Acme Rights")
      assert Games.taken_down?(down)
      assert down.takedown_reason == "copyright claim"
      assert down.takedown_complainant == "Acme Rights"
      assert Enum.any?(Games.list_taken_down(), &(&1.id == game.id))

      {:ok, restored} = Games.restore_game(down)
      refute Games.taken_down?(restored)
      assert restored.takedown_reason == nil
      assert Games.list_taken_down() == []
    end

    test "list_games_with_documents/0 hides taken-down games" do
      game = game_fixture()
      {:ok, _} = Games.take_down_game(game, "claim", "x")
      refute Enum.any?(Games.list_games_with_documents(), &(&1.id == game.id))
    end
  end

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

  describe "find_user_answer_duplicate/4" do
    setup do
      {:ok, game} = Games.create_game(%{name: "AnsDupGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "ansdup",
          email: "ansdup@test.com",
          password_hash: "x"
        })

      {:ok, prior} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "how does a turn go?",
          answer: "Roll 3 dice, then move.",
          visibility: "private"
        })

      %{game: game, user: user, prior: prior}
    end

    test "matches an own answer up to whitespace/case", %{game: game, user: user, prior: prior} do
      assert %{id: id} =
               Games.find_user_answer_duplicate(game.id, user.id, "roll 3   DICE,\nthen move.", -1)

      assert id == prior.id
    end

    test "excludes the provisional row itself", %{game: game, user: user, prior: prior} do
      assert Games.find_user_answer_duplicate(game.id, user.id, "Roll 3 dice, then move.", prior.id) ==
               nil
    end

    test "does not match another user's identical answer", %{game: game, prior: prior} do
      other =
        Repo.insert!(%RuleMaven.Users.User{
          username: "ansdup2",
          email: "ansdup2@test.com",
          password_hash: "x"
        })

      assert Games.find_user_answer_duplicate(game.id, other.id, prior.answer, -1) == nil
    end

    test "nil user_id or blank answer returns nil", %{game: game, user: user} do
      assert Games.find_user_answer_duplicate(game.id, nil, "Roll 3 dice, then move.", -1) == nil
      assert Games.find_user_answer_duplicate(game.id, user.id, "   ", -1) == nil
    end
  end

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

  describe "list_canonical_questions/2" do
    setup do
      {:ok, game} = Games.create_game(%{name: "CanonGame"})

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "canon_user",
          email: "canon@test.com",
          password_hash: "x"
        })

      %{game: game, user: user}
    end

    test "returns cleaned_question text for pooled, eligible rows", %{game: game, user: user} do
      {:ok, _q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "how many players can I do?",
          cleaned_question: "What is the maximum number of players?",
          answer: "5",
          visibility: "private",
          pooled: true
        })

      assert Games.list_canonical_questions(game.id) == ["What is the maximum number of players?"]
    end

    test "excludes refused, needs_review, and never-pooled/non-community rows", %{
      game: game,
      user: user
    } do
      base = %{game_id: game.id, user_id: user.id, answer: "A", visibility: "private"}

      Games.log_question(Map.merge(base, %{question: "q1", cleaned_question: "Refused Q", refused: true, pooled: true}))
      Games.log_question(Map.merge(base, %{question: "q2", cleaned_question: "Needs Review Q", needs_review: true, pooled: true}))
      Games.log_question(Map.merge(base, %{question: "q3", cleaned_question: "Never Pooled Q", pooled: false}))

      assert Games.list_canonical_questions(game.id) == []
    end

    test "community-visibility rows are eligible even when not pooled", %{game: game, user: user} do
      {:ok, _q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "q",
          cleaned_question: "Community Canonical Q",
          answer: "A",
          visibility: "community",
          pooled: false
        })

      assert Games.list_canonical_questions(game.id) == ["Community Canonical Q"]
    end

    test "scoped to the given game only", %{game: game, user: user} do
      {:ok, other_game} = Games.create_game(%{name: "OtherCanonGame"})

      Games.log_question(%{
        game_id: other_game.id,
        user_id: user.id,
        question: "q",
        cleaned_question: "Other Game Q",
        answer: "A",
        visibility: "private",
        pooled: true
      })

      assert Games.list_canonical_questions(game.id) == []
    end
  end

  describe "create_document/1 content-hash dedup" do
    import Ecto.Query
    alias RuleMaven.Games.Document

    defp doc_count(game_id),
      do: Repo.aggregate(from(d in Document, where: d.game_id == ^game_id), :count)

    defp real_text, do: String.duplicate("A rulebook page with plenty of real words. ", 40)

    test "a re-ingest of the same file (same game + hash) returns the existing doc" do
      {:ok, game} = Games.create_game(%{name: "HashDedupGame"})

      attrs = %{
        game_id: game.id,
        label: "Rulebook",
        full_text: real_text(),
        file_hash: "deadbeefhash"
      }

      {:ok, doc1} = Games.create_document(attrs)
      # Simulates a retried DownloadWorker attempt: same content, new pdf filename.
      {:ok, doc2} =
        Games.create_document(Map.merge(attrs, %{label: "Rulebook (retry)", pdf_path: "uploads/x2.pdf"}))

      assert doc2.id == doc1.id
      assert doc_count(game.id) == 1
    end

    test "a different file_hash creates a separate doc" do
      {:ok, game} = Games.create_game(%{name: "HashDistinctGame"})
      base = %{game_id: game.id, label: "A", full_text: real_text()}

      {:ok, _} = Games.create_document(Map.put(base, :file_hash, "hash-a"))
      {:ok, _} = Games.create_document(Map.merge(base, %{label: "B", file_hash: "hash-b"}))

      assert doc_count(game.id) == 2
    end

    test "sources without a file_hash are never deduped (pasted/legacy)" do
      {:ok, game} = Games.create_game(%{name: "NoHashGame"})
      base = %{game_id: game.id, label: "Pasted", full_text: real_text()}

      {:ok, _} = Games.create_document(base)
      {:ok, _} = Games.create_document(base)

      assert doc_count(game.id) == 2
    end
  end

  describe "create_document/1 save-only (unextracted)" do
    import Ecto.Query
    alias RuleMaven.Games.{Chunk, Document}

    test "a source with no page text is saved pending_review, unchunked, unpublished" do
      {:ok, game} = Games.create_game(%{name: "SaveOnlyGame"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rulebook",
          pdf_path: "uploads/rulebooks/x.pdf",
          pages: []
        })

      assert doc.status == "pending_review"
      assert doc.pages == []
      assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) == 0
    end

    test "an extracted source is still chunked and can auto-publish" do
      {:ok, game} = Games.create_game(%{name: "ExtractedGame"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rulebook",
          full_text: String.duplicate("A real rulebook sentence with plenty of words. ", 40)
        })

      assert doc.status == "published"
      assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) > 0
    end
  end
end
