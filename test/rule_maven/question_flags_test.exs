defmodule RuleMaven.QuestionFlagsTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Users}

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{username: name, email: "#{name}@test.com", password: "testpass1234"})

    u
  end

  defp log(game, author) do
    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "How does scoring work?",
        answer: "You count points.",
        user_id: author && author.id
      })

    q
  end

  setup do
    game = game_fixture()
    author = user_fixture("author")
    %{game: game, q: log(game, author)}
  end

  test "flagging records an open flag and shows in the user's set", %{q: q} do
    u = user_fixture("reporter")
    assert {:ok, _} = Games.flag_question(q.id, u.id, "wrong rule")

    assert MapSet.member?(Games.user_flagged_ids(u.id), q.id)
    assert Games.count_pending_flags() == 1
  end

  test "re-flagging is idempotent per user and updates the reason", %{q: q} do
    u = user_fixture("reporter2")
    {:ok, _} = Games.flag_question(q.id, u.id, "first")
    {:ok, _} = Games.flag_question(q.id, u.id, "second")

    flagged = Games.list_flagged_questions()
    entry = Enum.find(flagged, &(&1.question_log_id == q.id))
    assert entry.flag_count == 1
    assert entry.reasons == ["second"]
  end

  test "count_pending_flags counts distinct answers, not raw flags", %{game: game, q: q} do
    other = log(game, user_fixture("author2"))
    Games.flag_question(q.id, user_fixture("r1").id, nil)
    Games.flag_question(q.id, user_fixture("r2").id, nil)
    Games.flag_question(other.id, user_fixture("r3").id, nil)

    assert Games.count_pending_flags() == 2
    entry = Enum.find(Games.list_flagged_questions(), &(&1.question_log_id == q.id))
    assert entry.flag_count == 2
  end

  test "resolving clears open flags and drops from pending", %{q: q} do
    Games.flag_question(q.id, user_fixture("r4").id, nil)
    Games.flag_question(q.id, user_fixture("r5").id, nil)

    assert Games.resolve_flags(q.id) == 2
    assert Games.count_pending_flags() == 0
    assert Games.list_flagged_questions() == []
  end

  test "re-flagging a resolved answer re-opens it", %{q: q} do
    u = user_fixture("r6")
    Games.flag_question(q.id, u.id, nil)
    Games.resolve_flags(q.id)
    assert Games.count_pending_flags() == 0

    {:ok, _} = Games.flag_question(q.id, u.id, "still wrong")
    assert Games.count_pending_flags() == 1
    assert MapSet.member?(Games.user_flagged_ids(u.id), q.id)
  end

  test "anonymous (nil user) cannot flag", %{q: q} do
    assert {:error, _} = Games.flag_question(q.id, nil)
    assert Games.user_flagged_ids(nil) == MapSet.new()
  end

  test "deleting a question cascades its flags", %{q: q} do
    Games.flag_question(q.id, user_fixture("r7").id, nil)
    Games.delete_question(q)
    assert Games.count_pending_flags() == 0
  end
end
