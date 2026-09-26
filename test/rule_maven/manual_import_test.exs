defmodule RuleMaven.ManualImportTest do
  # Pages transcribed outside the extraction pipeline enter through the normal
  # document path: chunked, readiness-aware, and already clean.
  use RuleMaven.DataCase, async: true

  import Ecto.Query

  alias RuleMaven.{Games, ManualImport, Readiness, Repo}
  alias RuleMaven.Games.Chunk

  defp game do
    {:ok, g} = Games.create_game(%{name: "Manual #{System.unique_integer([:positive])}"})
    g
  end

  test "imports pages as a clean, chunked source past review and cleanup" do
    game = game()

    assert {:ok, doc} =
             ManualImport.import(game, %{
               "label" => "Core Rulebook",
               "pages" => [
                 %{"sheet" => 1, "printed" => 38, "text" => "QUEST 0: TUTORIAL\nsetup"},
                 %{
                   "sheet" => 2,
                   "printed" => 39,
                   "text" => "At Mimic's location, discard a 6+ token."
                 }
               ]
             })

    assert [%{lane: "manual", confidence: 1.0, cleaned: "QUEST 0: TUTORIAL\nsetup"}, _] =
             doc.pages

    contents = Repo.all(from c in Chunk, where: c.document_id == ^doc.id, select: c.content)
    assert Enum.any?(contents, &(&1 =~ "[Page 39]\n(Continues: QUEST 0: TUTORIAL)"))

    docs = Games.list_documents(game)

    for step <- [:extract, :review, :cleanup],
        do: assert(Readiness.step_complete?(step, game, docs))
  end

  test "rejects a blank page instead of importing a hole" do
    assert {:error, {:blank_page, 1}} =
             ManualImport.import(game(), %{
               "pages" => [%{"text" => "ok"}, %{"text" => ""}]
             })
  end

  test "copies the source PDF into uploads" do
    src = Path.join(System.tmp_dir!(), "manual_import_#{System.unique_integer([:positive])}.pdf")
    File.write!(src, "%PDF-1.4 fake")

    {:ok, doc} =
      ManualImport.import(game(), %{"pdf" => src, "pages" => [%{"text" => "rules"}]})

    assert doc.pdf_path =~ ~r{^uploads/rulebooks/\d+_manual_import_}
    assert File.read!(RuleMaven.Uploads.resolve(doc.pdf_path)) == "%PDF-1.4 fake"
    File.rm(RuleMaven.Uploads.resolve(doc.pdf_path))
    File.rm(src)
  end
end
