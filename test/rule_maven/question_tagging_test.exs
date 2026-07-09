defmodule RuleMaven.QuestionTaggingTest do
  @moduledoc """
  Category tagging is a pure pgvector nearest-neighbour search, so the tests pin
  exact cosine distances with hand-built unit vectors rather than real
  embeddings.

  All vectors live in the first three dimensions (the rest are zero padding), so
  for unit vectors `cosine_distance = 1 - cos(angle)`. Categories sit on the
  basis vectors `A = [1,0,0]` and `B = [0,1,0]`; a question's distance to `A` is
  therefore `1 - <first component>`.
  """
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{GameCategory, QuestionCategoryTag, QuestionLog}

  @dim 768

  # Pad a short vector out to the embedding width and wrap it for pgvector.
  defp vec(components) do
    Pgvector.new(components ++ List.duplicate(0.0, @dim - length(components)))
  end

  defp category(game, name, components) do
    Repo.insert!(%GameCategory{
      game_id: game.id,
      name: name,
      description: "#{name} rules.",
      name_embedding: vec(components)
    })
  end

  # A question whose embedding is exactly `components`.
  defp question(game, text, components) do
    {:ok, q} = Games.log_question(%{game_id: game.id, question: text, answer: "Because."})

    q
    |> Ecto.Changeset.change(%{question_embedding: vec(components)})
    |> Repo.update!()
  end

  defp tag_ids(question) do
    QuestionCategoryTag
    |> Repo.all()
    |> Enum.filter(&(&1.question_log_id == question.id))
    |> Enum.map(& &1.game_category_id)
    |> Enum.sort()
  end

  defp setup_game(_) do
    game = published_game_fixture(%{name: "Tagging Game"})
    a = category(game, "Alpha", [1.0, 0.0, 0.0])
    b = category(game, "Beta", [0.0, 1.0, 0.0])
    %{game: game, a: a, b: b}
  end

  describe "tag_question/2" do
    setup [:setup_game]

    test "tags only the categories that clear the strict 0.62 bar", %{game: game, a: a} do
      # [cos 15°, sin 15°] → d(Alpha)=0.034, d(Beta)=0.741. Only Alpha clears.
      q = question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])

      assert {:ok, 1} = Games.tag_question(q.id, game.id)
      assert tag_ids(q) == [a.id]
    end

    test "tags up to two categories when both clear the strict bar", %{game: game, a: a, b: b} do
      # [cos 45°, sin 45°] → d = 0.293 to both.
      q = question(game, "Straddles both?", [0.7071, 0.7071, 0.0])

      assert {:ok, 2} = Games.tag_question(q.id, game.id)
      assert tag_ids(q) == Enum.sort([a.id, b.id])
    end

    test "falls back to the single nearest category when nothing clears the strict bar",
         %{game: game, a: a, b: b} do
      # Equidistant from Alpha and Beta at d=0.695 — over 0.62, under 0.75.
      # This is the real "How many players can play?" case.
      q = question(game, "How many players can play?", [0.305, 0.305, 0.9022])

      assert {:ok, 1} = Games.tag_question(q.id, game.id)
      # Exactly one tag: a loose match must never stack two categories.
      assert length(tag_ids(q)) == 1
      assert hd(tag_ids(q)) in [a.id, b.id]
    end

    test "tags nothing when even the nearest category is beyond the fallback bar",
         %{game: game} do
      # d = 0.9 to both categories.
      q = question(game, "Totally unrelated?", [0.1, 0.1, 0.98995])

      assert {:ok, 0} = Games.tag_question(q.id, game.id)
      assert tag_ids(q) == []
    end

    test "skips a question with no embedding", %{game: game} do
      {:ok, q} = Games.log_question(%{game_id: game.id, question: "No vector?", answer: "n/a"})

      assert :skipped = Games.tag_question(q.id, game.id)
      assert tag_ids(q) == []
    end
  end

  describe "retag_all_questions/1" do
    setup [:setup_game]

    test "reports {tagged, total} counting only questions that got a category",
         %{game: game} do
      question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])
      question(game, "Totally unrelated?", [0.1, 0.1, 0.98995])

      # 2 embedded questions, only 1 lands a category.
      assert {1, 2} = Games.retag_all_questions(game)
    end

    test "is a true re-tag: drops stale tags instead of only adding",
         %{game: game, a: a, b: b} do
      q = question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])

      # A stale tag pointing at Beta, which this question does not match.
      Repo.insert!(%QuestionCategoryTag{question_log_id: q.id, game_category_id: b.id})
      assert b.id in tag_ids(q)

      assert {1, 1} = Games.retag_all_questions(game)

      # Beta is gone, Alpha remains — the re-tag removed the bad tag.
      assert tag_ids(q) == [a.id]
    end

    test "is idempotent — re-running does not duplicate tags", %{game: game, a: a} do
      q = question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])

      assert {1, 1} = Games.retag_all_questions(game)
      assert {1, 1} = Games.retag_all_questions(game)
      assert tag_ids(q) == [a.id]
    end

    test "ignores questions with no embedding in the total", %{game: game} do
      question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])
      {:ok, _} = Games.log_question(%{game_id: game.id, question: "No vector?", answer: "n/a"})

      assert {1, 1} = Games.retag_all_questions(game)
    end

    test "reports zero total when the game has no questions", %{game: game} do
      assert {0, 0} = Games.retag_all_questions(game)
    end
  end

  describe "refused questions" do
    setup [:setup_game]

    test "refused questions are not re-tagged", %{game: game} do
      q = question(game, "Alpha-ish question?", [0.9659, 0.2588, 0.0])
      Repo.update!(Ecto.Changeset.change(Repo.get!(QuestionLog, q.id), %{refused: true}))

      assert {0, 0} = Games.retag_all_questions(game)
    end
  end
end
