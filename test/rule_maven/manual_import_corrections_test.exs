defmodule RuleMaven.ManualImportCorrectionsTest do
  use RuleMaven.DataCase, async: false

  import Ecto.Query

  alias RuleMaven.{Games, ManualImport, Repo, Users}
  alias RuleMaven.Audit.AuditLog
  alias RuleMaven.Games.{QuestionFlag, QuestionLog}
  alias RuleMaven.ManualImport.Corrections

  @turn "Choose a card in the tavern being resolved. Perform a coin trade if you played your coin of value 0."

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    {:ok, game} = Games.create_game(%{name: "Corr #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      ManualImport.import(game, %{
        "label" => "Rulebook",
        "pages" => [%{"sheet" => 9, "printed" => 9, "text" => @turn}]
      })

    Repo.update!(Ecto.Changeset.change(doc, status: "published"))

    {:ok, user} =
      Users.create_user(%{username: "corr", email: "corr@test.com", password: "password1234"})

    {:ok, row} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Do you take a card when bidding 0?",
        answer: "No, you do not take a card. Instead you trade.",
        verdict: "info",
        expansion_ids: []
      })

    %{game: game, user: user, row: row}
  end

  defp flag!(row, user, reason),
    do: Repo.insert!(%QuestionFlag{question_log_id: row.id, user_id: user.id, reason: reason})

  @fix %{
    "answer" => "Yes, you still choose a card, then trade.",
    "verdict" => "legal",
    "citations" => [%{"quote" => "Choose a card in the tavern being resolved", "page" => 9}],
    "note" => "p.9 turn order"
  }

  test "queue holds flagged and thumbs-down answers, not clean ones", %{
    game: game,
    user: user,
    row: row
  } do
    {:ok, clean} =
      Games.log_question(%{
        game_id: game.id,
        question: "x?",
        answer: "y",
        verdict: "info",
        expansion_ids: []
      })

    {:ok, down} =
      Games.log_question(%{
        game_id: game.id,
        question: "z?",
        answer: "w",
        verdict: "info",
        expansion_ids: [],
        feedback: "down"
      })

    flag!(row, user, "wrong")

    ids = Corrections.queue(game_id: game.id) |> Enum.map(& &1.question.id)
    assert hd(ids) == row.id
    assert down.id in ids
    refute clean.id in ids
  end

  test "correct verifies citations, pools the fix, resolves flags, and leaves the queue", %{
    game: game,
    user: user,
    row: row
  } do
    flag!(row, user, "wrong")

    assert {:ok, fixed} = Corrections.correct(row, @fix, user)
    assert fixed.answer =~ "still choose a card"
    assert fixed.pooled and fixed.citation_valid
    assert fixed.llm_provider == "manual"

    assert Repo.all(
             from f in QuestionFlag, where: f.question_log_id == ^row.id, select: f.resolved
           ) == [true]

    assert Repo.exists?(
             from a in AuditLog,
               where: a.action == "answer.manual_correction" and a.target_id == ^row.id
           )

    assert Corrections.queue(game_id: game.id) == []
  end

  test "an ungrounded correction writes nothing", %{user: user, row: row} do
    bad =
      Map.put(@fix, "citations", [
        %{"quote" => "You may always take two cards when bidding zero", "page" => 9}
      ])

    assert {:error, {:ungrounded, _}} = Corrections.correct(row, bad, user)
    assert Repo.get!(QuestionLog, row.id).answer == row.answer
  end

  test "uphold resolves flags and a thumbs-down leaves the queue once reviewed", %{
    game: game,
    user: user,
    row: row
  } do
    flag!(row, user, "wrong")
    Repo.update!(Ecto.Changeset.change(row, feedback: "down"))

    assert [{_, :ok}] =
             Corrections.apply_all([%{"question" => row.id, "action" => "uphold"}], user)

    assert Corrections.queue(game_id: game.id) == []
  end

  test "apply_all reports unknown rows and actions", %{user: user, row: row} do
    assert [{-1, {:error, :not_found}}, {_, {:error, :bad_action}}] =
             Corrections.apply_all(
               [%{"question" => -1}, %{"question" => row.id, "action" => "x"}],
               user
             )
  end
end
