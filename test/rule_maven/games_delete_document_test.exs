defmodule RuleMaven.GamesDeleteDocumentTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Settings}

  defp game, do: elem(Games.create_game(%{name: "Del #{System.unique_integer([:positive])}"}), 1)

  defp doc_with_file(game) do
    pdf_path = "rulebooks/del_#{System.unique_integer([:positive])}.pdf"
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

  test "removes the stored PDF file from disk" do
    game = game()
    {doc, full} = doc_with_file(game)
    assert File.exists?(full)

    Games.delete_document(doc)

    refute File.exists?(full)
  end

  test "clears per-game generation caches when deleting the last document" do
    game = game()
    {doc, _full} = doc_with_file(game)
    Settings.put("cheat_content_#{game.id}", "stale")
    Settings.put("suggestions_#{game.id}", "[]")
    Settings.put("categories_#{game.id}", "[]")

    Games.delete_document(doc)

    assert Settings.get("cheat_content_#{game.id}") == nil
    assert Settings.get("suggestions_#{game.id}") == nil
    assert Settings.get("categories_#{game.id}") == nil
  end

  test "keeps per-game caches when another document remains" do
    game = game()
    {doc1, _} = doc_with_file(game)
    {_doc2, _} = doc_with_file(game)
    Settings.put("cheat_content_#{game.id}", "keep")

    Games.delete_document(doc1)

    assert Settings.get("cheat_content_#{game.id}") == "keep"
  end
end
