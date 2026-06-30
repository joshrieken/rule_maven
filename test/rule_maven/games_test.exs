defmodule RuleMaven.GamesTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games
  alias RuleMaven.Repo
  import RuleMaven.GamesFixtures

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
end
