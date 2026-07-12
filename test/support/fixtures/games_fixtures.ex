defmodule RuleMaven.GamesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `RuleMaven.Games` context.
  """

  import Ecto.Query

  @doc """
  Generate a game.
  """
  def game_fixture(attrs \\ %{}) do
    {:ok, game} =
      attrs
      |> Enum.into(%{
        bgg_id: 42,
        name: "some name"
      })
      |> RuleMaven.Games.create_game()

    game
  end

  @doc """
  Generate a game with a published rulebook document, flagged `playable` so it
  appears in the default "playable" catalog view (which lists games whose
  readiness pipeline is complete — see `RuleMaven.Readiness`).
  """
  def published_game_fixture(attrs \\ %{}) do
    game = game_fixture(attrs)

    {:ok, _doc} =
      %RuleMaven.Games.Document{}
      |> RuleMaven.Games.Document.changeset(%{
        label: "Rulebook",
        full_text: "Test rulebook text.",
        game_id: game.id,
        status: "published"
      })
      |> RuleMaven.Repo.insert()

    {:ok, game} =
      game
      |> Ecto.Changeset.change(
        playable: true,
        playable_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> RuleMaven.Repo.update()

    game
  end

  @doc """
  A published game plus `question_count` already-answered questions from the
  same user, each with distinct text — questions are self-contained rows (no
  followup threading, see `Games.grouped_questions/2`), so `question_count`
  DIFFERENT questions is what it takes to get `question_count` distinct
  threads in the sidebar / Q&A pager. Rows are inserted with increasing
  `inserted_at` so `n` is the newest (matches `sort_thread_summaries/1`'s
  recency-desc order, and `assign_qa_nav/1`'s "default to newest" pick).
  """
  def qa_thread_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    question_count = Map.get(attrs, :question_count, 2)
    game = published_game_fixture(Map.get(attrs, :game_attrs, %{}))

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "qa_thread_user_#{System.unique_integer([:positive])}",
        email: "qa_thread_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    base = DateTime.utc_now() |> DateTime.truncate(:second)

    thread_ids =
      for n <- 1..question_count do
        {:ok, ql} =
          RuleMaven.Games.log_question(%{
            game_id: game.id,
            user_id: user.id,
            question: "Test question #{n}?",
            answer: "Test answer #{n}.",
            visibility: "private"
          })

        # `inserted_at` isn't cast by the changeset (Ecto stamps it on
        # insert), so back-date it explicitly per row to make sidebar/pager
        # ordering deterministic regardless of how fast inserts run.
        RuleMaven.Repo.update_all(
          from(q in RuleMaven.Games.QuestionLog, where: q.id == ^ql.id),
          set: [inserted_at: DateTime.add(base, n, :second)]
        )

        ql.id
      end

    %{game: game, user: user, thread_ids: thread_ids}
  end
end
