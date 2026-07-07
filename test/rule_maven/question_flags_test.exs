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
    # set_question_visibility enqueues SettleVotesWorker, so Oban must be
    # supervised here (same pattern as moderation_test.exs).
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

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

  # ── report_answer: trust-tiered auto-pull ──────────────────────────────────

  defp reload(q), do: RuleMaven.Repo.get(RuleMaven.Games.QuestionLog, q.id)
  defp make_community(q), do: Games.set_question_visibility(q.id, "community")

  defp make_verified(q) do
    {:ok, _} =
      q
      |> Ecto.Changeset.change(verified: true, visibility: "community")
      |> RuleMaven.Repo.update()
  end

  test "provisional answer is pulled on the first report", %{q: q} do
    assert {:ok, %{pulled: true}} = Games.report_answer(q.id, user_fixture("pr1"))
    assert reload(q).needs_review
  end

  test "community answer needs a quorum of reporters before auto-pull", %{q: q} do
    make_community(q)

    assert {:ok, %{pulled: false}} = Games.report_answer(q.id, user_fixture("cr1"))
    assert {:ok, %{pulled: false}} = Games.report_answer(q.id, user_fixture("cr2"))
    refute reload(q).needs_review

    # Third distinct reporter crosses the default quorum of 3.
    assert {:ok, %{pulled: true}} = Games.report_answer(q.id, user_fixture("cr3"))
    assert reload(q).needs_review
  end

  test "suspended reporters don't count toward quorum", %{q: q} do
    make_community(q)

    Games.report_answer(q.id, user_fixture("sr1"))
    Games.report_answer(q.id, user_fixture("sr2"))

    suspended = user_fixture("sr3")
    {:ok, _} = Users.suspend_user(suspended)
    assert {:ok, %{pulled: false}} = Games.report_answer(q.id, suspended)
    refute reload(q).needs_review
  end

  test "admin-verified answers are never auto-pulled", %{q: q} do
    make_verified(q)

    for n <- 1..4 do
      assert {:ok, %{pulled: false}} = Games.report_answer(q.id, user_fixture("vr#{n}"))
    end

    refute reload(q).needs_review
  end

  test "report respects the daily flag quota", %{game: game} do
    RuleMaven.Settings.put("flag_limit_daily", "2")
    u = user_fixture("quota")

    [a, b, c] =
      for _ <- 1..3, do: log(game, user_fixture("a#{System.unique_integer([:positive])}"))

    assert {:ok, _} = Games.report_answer(a.id, u)
    assert {:ok, _} = Games.report_answer(b.id, u)
    assert {:error, _} = Games.report_answer(c.id, u)
  end

  test "an already-pulled answer reports without double-acting", %{q: q} do
    assert {:ok, %{pulled: true}} = Games.report_answer(q.id, user_fixture("dup1"))
    # Second reporter: flag still records, but it's already out of the pool.
    assert {:ok, %{pulled: false}} = Games.report_answer(q.id, user_fixture("dup2"))
  end

  # ── pull_for_review: admin direct moderation replaces admin reporting ──────

  defp admin_fixture(name) do
    {:ok, admin} = Users.update_user_role(user_fixture(name), "admin")
    admin
  end

  test "admins cannot report — directed to pull_for_review instead", %{q: q} do
    assert {:error, message} = Games.report_answer(q.id, admin_fixture("adm1"))
    assert message =~ "Pull for review"
    # No flag row was written and nothing was pulled.
    assert Games.count_pending_flags() == 0
    refute reload(q).needs_review
  end

  test "pull_for_review pulls immediately for an admin, without a flag row", %{q: q} do
    admin = admin_fixture("adm2")

    assert {:ok, %{pulled: true}} = Games.pull_for_review(q.id, admin)
    assert reload(q).needs_review
    assert Games.count_pending_flags() == 0

    # Idempotent: already pulled reports back pulled: false, stays pulled.
    assert {:ok, %{pulled: false}} = Games.pull_for_review(q.id, admin)
    assert reload(q).needs_review
  end

  test "pull_for_review is denied for non-admins", %{q: q} do
    assert {:error, "Not authorized."} = Games.pull_for_review(q.id, user_fixture("pleb"))
    refute reload(q).needs_review
  end

  test "pull_for_review on a missing id errors cleanly" do
    assert {:error, "Answer not found."} = Games.pull_for_review(-1, admin_fixture("adm3"))
  end
end
