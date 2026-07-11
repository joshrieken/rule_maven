defmodule RuleMaven.GamesResetPreparationTest do
  use RuleMaven.DataCase, async: true

  import Ecto.Query

  alias RuleMaven.{Games, Settings, Repo}
  alias RuleMaven.Games.{Document, Chunk, GameCategory}
  alias RuleMaven.Voices.GameVoice

  defp game,
    do: elem(Games.create_game(%{name: "Reset #{System.unique_integer([:positive])}"}), 1)

  defp doc_with_file(game) do
    pdf_path = "rulebooks/reset_#{System.unique_integer([:positive])}.pdf"
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

  defp seed_enrichments(game) do
    Settings.put("suggestions_#{game.id}", "[]")
    Settings.put("categories_#{game.id}", "[]")
    Settings.put("did_you_know_#{game.id}", "[]")
    Settings.put("cheat_content_#{game.id}", "stale")
    Settings.put("setup_content_#{game.id}", "stale")
    Settings.put("first_player_#{game.id}", "[]")
    Settings.put("common_mistakes_#{game.id}", "[]")
    Settings.put("quiz_#{game.id}", "[]")
    Settings.put("delta_content_#{game.id}", "stale")

    Repo.insert!(%GameCategory{game_id: game.id, name: "Combat", description: "fights"})

    Repo.insert!(%GameVoice{
      game_id: game.id,
      slug: "gruff-captain",
      label: "Gruff Captain",
      emoji: "🏴‍☠️",
      style: "barks orders"
    })

    {:ok, _} = Games.update_game(game, %{theme_palette: %{"light" => %{"--accent" => "#fff"}}})
  end

  test "wipes documents, enrichments and personas — keeps game, bgg_data, theme palette" do
    game = game()
    {doc, full} = doc_with_file(game)
    seed_enrichments(game)
    Repo.insert!(%Chunk{document_id: doc.id, chunk_index: 0, content: "x"})

    assert :ok = Games.reset_preparation(game)

    refute File.exists?(full)
    assert Repo.aggregate(from(d in Document, where: d.game_id == ^game.id), :count) == 0
    assert Repo.aggregate(from(c in GameCategory, where: c.game_id == ^game.id), :count) == 0
    assert Settings.get("suggestions_#{game.id}") == nil
    assert Settings.get("categories_#{game.id}") == nil
    assert Settings.get("did_you_know_#{game.id}") == nil
    assert Settings.get("cheat_content_#{game.id}") == nil
    assert Settings.get("setup_content_#{game.id}") == nil
    assert Settings.get("first_player_#{game.id}") == nil
    assert Settings.get("common_mistakes_#{game.id}") == nil
    assert Settings.get("quiz_#{game.id}") == nil
    assert Settings.get("delta_content_#{game.id}") == nil
    assert Repo.aggregate(from(gv in GameVoice, where: gv.game_id == ^game.id), :count) == 0

    assert Repo.get(RuleMaven.Games.Game, game.id).theme_palette == %{
             "light" => %{"--accent" => "#fff"}
           }
  end

  test "is a no-op-safe :ok when there is nothing to reset" do
    assert :ok = Games.reset_preparation(game())
  end

  test "stamps a reset timestamp used to scope the cost readout" do
    game = game()
    assert Games.preparation_reset_at(game.id) == nil

    assert :ok = Games.reset_preparation(game)

    assert %DateTime{} = Games.preparation_reset_at(game.id)
  end

  test "refuses and deletes nothing when the game has logged questions" do
    game = game()
    {_doc, full} = doc_with_file(game)
    seed_enrichments(game)

    {:ok, _} =
      Games.log_question(%{game_id: game.id, question: "How do I win?", answer: "Score points."})

    assert {:error, :has_questions} = Games.reset_preparation(game)

    assert File.exists?(full)
    assert Repo.aggregate(from(d in Document, where: d.game_id == ^game.id), :count) == 1
    assert Settings.get("cheat_content_#{game.id}") == "stale"
    assert Repo.aggregate(from(gv in GameVoice, where: gv.game_id == ^game.id), :count) == 1
  end
end
