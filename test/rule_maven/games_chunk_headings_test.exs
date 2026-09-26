defmodule RuleMaven.GamesChunkHeadingsTest do
  # A scenario's rules often continue onto a page without its title. On
  # Zombicide: Black Plague, Quest 0's special rules (p.39) reached the model
  # unlabeled and it credited them to another quest. Continuation chunks now
  # carry the heading in effect.
  use RuleMaven.DataCase, async: true

  import Ecto.Query

  alias RuleMaven.Games
  alias RuleMaven.Games.{Chunk, Document}
  alias RuleMaven.Repo

  defp chunk_contents(pages) do
    {:ok, game} = Games.create_game(%{name: "Headings #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        game_id: game.id,
        label: "Rules",
        full_text: "x",
        pages:
          pages
          |> Enum.with_index()
          |> Enum.map(fn {{printed, text}, i} ->
            %{index: i, sheet: i + 1, printed: printed, text: text}
          end)
      })
      |> Repo.insert()

    Games.chunk_document(doc)

    Repo.all(
      from c in Chunk,
        where: c.document_id == ^doc.id,
        order_by: c.chunk_index,
        select: {c.page_number, c.content}
    )
  end

  test "a continuation page carries the scenario heading" do
    chunks =
      chunk_contents([
        {2, "CHAPTERS\nQUEST 0 DANSE MACABRE ................. 38\nQUEST 1 BIG GAME ..... 40"},
        {38, "QUESTS\nQUEST 0: TUTORIAL: DANSE MACABRE\nEASY / 4+ SURVIVORS"},
        {39,
         "SPECIAL RULES\nThe green Spawn Zone is inactive until the green Objective is taken."},
        {41, "QUEST 2: THE BLACK BOOK\nEASY / 6+ SURVIVORS"}
      ])

    page = fn n -> chunks |> Enum.find(&(elem(&1, 0) == n)) |> elem(1) end

    # The continuation is labeled, with the [Page N] marker still first.
    assert page.(39) =~ ~r/\A\[Page 39\]\n\(Continues: QUEST 0: TUTORIAL: DANSE MACABRE\)\n/

    # The heading's own page isn't re-labeled; the ToC page starts no carry.
    refute page.(38) =~ "Continues"
    refute page.(2) =~ "Continues"
    # A new heading replaces the old one rather than stacking under it.
    refute page.(41) =~ "Continues"
  end

  test "the carry stops one page after its heading" do
    chunks =
      chunk_contents([
        {10, "QUEST 5: LAST STAND\nsetup"},
        {11, "special rules"},
        {12, "more rules"},
        {13, "REFERENCE TABLES\nnot part of the quest"}
      ])

    by_page = Map.new(chunks)
    assert by_page[11] =~ "(Continues: QUEST 5: LAST STAND)"
    # One page past the heading is the limit: the next page may already be a
    # reference section (Black Plague's SKILLS followed Quest 10's map page).
    refute by_page[12] =~ "Continues"
    refute by_page[13] =~ "Continues"
  end

  test "decorated headings with the name on the next line" do
    chunks =
      chunk_contents([
        {40, "◆QUEST 1:\nBIG GAME HUNTING\nsetup"},
        {41, "special rules one"},
        {43, "[diamond shape] QUEST 4:\n# FAMINE\nsetup"},
        {44, "special rules four"},
        {46, "**QUEST 7:**\n# DEAD TRAIL\nsetup"},
        {47, "special rules seven"}
      ])

    by_page = Map.new(chunks)
    assert by_page[41] =~ "(Continues: QUEST 1: BIG GAME HUNTING)"
    assert by_page[44] =~ "(Continues: QUEST 4: FAMINE)"
    assert by_page[47] =~ "(Continues: QUEST 7: DEAD TRAIL)"
    # A page with its own heading is never labeled with the previous one.
    refute by_page[43] =~ "Continues"
  end
end
