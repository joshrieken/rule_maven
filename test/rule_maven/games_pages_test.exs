defmodule RuleMaven.GamesPagesTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games

  describe "paginate/1" do
    test "builds first-class page maps with sheet/printed/index" do
      pages = Games.paginate(["page one", "page two", "page three"])

      assert [
               %{index: 0, sheet: 1, text: "page one"},
               %{index: 1, sheet: 2, text: "page two"},
               %{index: 2, sheet: 3, text: "page three"}
             ] = pages
    end
  end

  describe "printed page-number detection" do
    defp printed(raw), do: Games.paginate(raw) |> Enum.map(& &1.printed)

    test "true unnumbered front matter (positive offset) stays nil" do
      # Printed page 1 only starts on sheet 5 (offset 4): the 4 lead sheets are
      # genuinely before page 1, so extrapolating back hits page <= 0 and is
      # left unnumbered.
      raw =
        List.duplicate("cover", 4) ++
          for n <- 1..6, do: "body text\n#{n}"

      assert printed(raw) == [nil, nil, nil, nil, 1, 2, 3, 4, 5, 6]
    end

    test "offset-0 numbering backfills earlier unlabelled pages (Clank case)" do
      # Cover + components splash carry no footer; the first detected number is
      # "3" on sheet 3 (offset 0). Sheets 1-2 are therefore pages 1-2, and an
      # unlabelled trailing sheet continues to page 7.
      raw = ["cover", "splash", "c\n3", "d\n4", "e\n5", "f\n6", "back (no number)"]
      assert printed(raw) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "interpolates printed numbers for unlabelled pages inside a run" do
      # Only some pages show a footer number; the rest are filled by offset.
      raw = ["a\n1", "b (no number)", "c\n3", "d (no number)", "e\n5"]
      assert printed(raw) == [1, 2, 3, 4, 5]
    end

    test "handles a numbering shift mid-book (two segments)" do
      # Sheets 1-4 -> printed 1-4 (offset 0). A 2-sheet unnumbered insert. Then
      # printed continues 5-8 on sheets 7-10 (offset 2).
      raw =
        for(n <- 1..4, do: "body\n#{n}") ++
          ["insert art", "insert art"] ++
          for n <- 5..8, do: "body\n#{n}"

      assert printed(raw) == [1, 2, 3, 4, nil, nil, 5, 6, 7, 8]
    end

    test "repairs OCR digit look-alikes in footer numbers" do
      # "l0" -> 10, "O" reading as zero, "1l" -> 11, etc.
      raw = ["x\nl0", "y\n1l", "z\nl2"]
      assert printed(raw) == [10, 11, 12]
    end

    test "a single stray number is not enough to anchor (noise rejected)" do
      raw = ["intro", "rules\n5", "more", "even more"]
      assert printed(raw) == [nil, nil, nil, nil]
    end

    test "detect_printed_offset reports the dominant run offset" do
      raw = List.duplicate("cover", 2) ++ for n <- 1..6, do: "body\n#{n}"
      # sheet 3 -> printed 1, so offset is 2.
      assert Games.detect_printed_offset(raw) == 2
    end

    test "no detectable numbers -> nil offset, all sheets fall back" do
      raw = ["alpha", "beta", "gamma"]
      assert Games.detect_printed_offset(raw) == nil
      assert printed(raw) == [nil, nil, nil]
    end
  end

  describe "assign_printed_from_anchor/2 (manual fallback)" do
    defp from_anchor(raw, sheet) do
      Games.paginate(raw)
      |> Games.assign_printed_from_anchor(sheet)
      |> Enum.map(& &1.printed)
    end

    test "anchor on sheet 1 numbers every page from 1" do
      assert from_anchor(["a", "b", "c"], 1) == [1, 2, 3]
    end

    test "anchor mid-book leaves earlier sheets unnumbered (front matter)" do
      assert from_anchor(["cover", "toc", "a", "b", "c"], 3) == [nil, nil, 1, 2, 3]
    end

    test "overwrites any previously detected numbers" do
      pages = [%{sheet: 1, printed: 9}, %{sheet: 2, printed: 9}, %{sheet: 3, printed: nil}]
      assert Games.assign_printed_from_anchor(pages, 2) |> Enum.map(& &1.printed) == [nil, 1, 2]
    end

    test "clamps a sub-1 anchor to sheet 1" do
      assert from_anchor(["a", "b"], 0) == [1, 2]
    end

    test "leaves page bodies untouched" do
      [p | _] = Games.paginate(["body text"]) |> Games.assign_printed_from_anchor(1)
      assert p.text == "body text"
    end
  end

  describe "strip_printed_number/2" do
    test "drops a bare page-number footer line" do
      assert Games.strip_printed_number("Some rule text here.\n3", 3) == "Some rule text here."
    end

    test "drops a 'Page N' header line" do
      assert Games.strip_printed_number("Page 12\nThe rule body.", 12) == "The rule body."
    end

    test "drops a decorated footer number" do
      assert Games.strip_printed_number("Body.\n— 7 —", 7) == "Body."
    end

    test "keeps a number that is part of a rule, not a header/footer" do
      text = "Setup\nPlace 3 cubes on the board.\nThen continue."
      assert Games.strip_printed_number(text, 3) == text
    end

    test "only strips the matching number, not other footer numbers" do
      assert Games.strip_printed_number("Rule about 5 things.\n9", 3) == "Rule about 5 things.\n9"
    end

    test "no-op when the page has no printed number" do
      assert Games.strip_printed_number("Body.\n4", nil) == "Body.\n4"
    end
  end

  describe "effective_page_text/1 layer precedence" do
    test "cleaned beats original" do
      assert Games.effective_page_text(%{text: "orig", cleaned: "clean"}) == "clean"
      assert Games.effective_page_text(%{text: "orig", cleaned: nil}) == "orig"
    end

    test "empty-string cleaned still counts (not skipped as nil)" do
      assert Games.effective_page_text(%{text: "orig", cleaned: ""}) == ""
    end

    test "rebuild_full_text uses effective text" do
      pages = [%{sheet: 1, printed: 1, text: "orig", cleaned: "clean"}]
      assert Games.rebuild_full_text(pages) =~ "clean"
      refute Games.rebuild_full_text(pages) =~ "orig"
    end
  end

  describe "rebuild_full_text/1 round-trips with paginate/1" do
    test "number_pages output equals rebuild_full_text(paginate(...))" do
      raw = ["alpha", "beta", "gamma"]
      assert Games.number_pages(raw) == Games.rebuild_full_text(Games.paginate(raw))
    end

    test "marked blob parses back to equivalent pages" do
      raw = ["alpha\n1", "beta\n2", "gamma\n3"]
      blob = Games.number_pages(raw)
      parsed = Games.pages_from_full_text(blob)

      # text bodies survive the round trip
      assert Enum.map(parsed, & &1.text) == raw
      # rebuilding from parsed pages reproduces the blob
      assert Games.rebuild_full_text(parsed) == blob
    end
  end

  describe "pages_from_full_text/1" do
    test "legacy blob without markers becomes positional pages" do
      blob = "first\fsecond\fthird"
      pages = Games.pages_from_full_text(blob)

      assert [
               %{index: 0, sheet: 1, printed: nil, text: "first"},
               %{index: 1, sheet: 2, printed: nil, text: "second"},
               %{index: 2, sheet: 3, printed: nil, text: "third"}
             ] = pages
    end
  end

  describe "create_document/1 derives pages from full_text" do
    test "pages are populated and persisted" do
      {:ok, game} = Games.create_game(%{name: "Pages Test"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "rule one\frule two"
        })

      assert length(doc.pages) == 2
      assert Enum.map(doc.pages, & &1.text) == ["rule one", "rule two"]
    end
  end

  describe "replace_page/3 (concurrent-write race)" do
    test "applies to fresh state, not clobbering a concurrent set_page_cleaned write" do
      {:ok, game} = Games.create_game(%{name: "Race Test #{System.unique_integer([:positive])}"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "page one text\fpage two text"
        })

      # Simulate the worker's load-then-wait-5-minutes: it holds this snapshot
      # from before the concurrent cleanup write below.
      stale_doc = Games.get_document!(doc.id)

      # A concurrent cleanup write lands on page 1 (index 1) while the
      # re-extract is "in flight".
      {:ok, _} = Games.set_page_cleaned(doc.id, 1, "freshly cleaned page two")

      # The re-extract now persists using the doc it loaded before that write.
      {:ok, updated} =
        Games.replace_page(stale_doc, 0, %{
          text: "re-extracted page one",
          confidence: 0.95,
          lane: "t1",
          source: "reextract"
        })

      page0 = Enum.find(updated.pages, &(&1.index == 0))
      page1 = Enum.find(updated.pages, &(&1.index == 1))

      assert page0.text == "re-extracted page one"
      # Must NOT be clobbered back to nil/original by the stale snapshot.
      assert page1.cleaned == "freshly cleaned page two"
    end

    test "an empty re-extraction never blanks a page that already has text" do
      # `reextract_page/3` seeds escalation with an empty cheap_text, and a
      # failed strong-model transcribe can return "". Writing that over a good
      # page is irrecoverable — there is no revert path.
      {:ok, game} = Games.create_game(%{name: "Blank #{System.unique_integer([:positive])}"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "page one text\fpage two text"
        })

      assert {:error, :empty_extraction} =
               Games.replace_page(doc, 0, %{
                 text: "",
                 confidence: 0.5,
                 lane: "t3",
                 source: "reextract"
               })

      # Whitespace-only is just as blank.
      assert {:error, :empty_extraction} =
               Games.replace_page(doc, 0, %{
                 text: "   \n  ",
                 confidence: 0.5,
                 lane: "t3",
                 source: "reextract"
               })

      reloaded = Games.get_document!(doc.id)
      assert Enum.find(reloaded.pages, &(&1.index == 0)).text == "page one text"
    end

    test "an empty re-extraction onto a page that does not exist is a harmless no-op" do
      # Empty pages are dropped at parse time, so a page that exists always has
      # text — the guard only ever fires where there is something to lose.
      {:ok, game} = Games.create_game(%{name: "Blank2 #{System.unique_integer([:positive])}"})

      {:ok, doc} =
        Games.create_document(%{game_id: game.id, label: "Rules", full_text: "only page"})

      assert {:ok, _} =
               Games.replace_page(doc, 99, %{
                 text: "",
                 confidence: 0.5,
                 lane: "t3",
                 source: "reextract"
               })
    end
  end

  describe "job log" do
    test "a run records its events in order and closes with a terminal state" do
      {:ok, game} = Games.create_game(%{name: "Log Test"})

      run = RuleMaven.Jobs.start_run("download", {"game", game.id}, "Log Test")
      RuleMaven.Jobs.event(run, "info", "Starting…")
      RuleMaven.Jobs.event(run, "page", "Page 1/2 — clean text layer ✓")
      RuleMaven.Jobs.finish_run(run, "done", "Done")

      # Newest first.
      events = RuleMaven.Jobs.events(run.id)
      assert Enum.map(events, & &1.message) == ["Page 1/2 — clean text layer ✓", "Starting…"]
      assert Enum.map(events, & &1.level) == ["page", "info"]

      assert RuleMaven.Jobs.get_run(run.id).state == "done"
    end
  end

  describe "page_needs_review?/1 and review_page_count/1" do
    test "flags low confidence, ignores nil/high" do
      refute Games.page_needs_review?(%{confidence: nil})
      refute Games.page_needs_review?(%{confidence: 0.9})
      refute Games.page_needs_review?(%{confidence: 0.6})
      assert Games.page_needs_review?(%{confidence: 0.5})
      assert Games.page_needs_review?(%{confidence: 0.0})
    end

    test "counts flagged pages in a list" do
      pages = [%{confidence: 0.9}, %{confidence: 0.5}, %{confidence: nil}, %{confidence: 0.3}]
      assert Games.review_page_count(pages) == 2
    end

    test "flags pages with residual defects regardless of confidence" do
      assert Games.page_needs_review?(%{confidence: nil, cleanup_defects: ["GARBLE: soup"]})
      assert Games.page_needs_review?(%{confidence: 0.9, cleanup_defects: ["JUNK: header"]})
      refute Games.page_needs_review?(%{confidence: 0.9, cleanup_defects: []})
      refute Games.page_needs_review?(%{confidence: 0.9, cleanup_defects: nil})
    end
  end

  describe "set_page_cleaned/4 (defects)" do
    setup do
      {:ok, game} = Games.create_game(%{name: "Defects #{System.unique_integer([:positive])}"})

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "page one text\fpage two text"
        })

      %{doc: doc}
    end

    test "writes cleanup_defects alongside the cleaned text", %{doc: doc} do
      {:ok, _} = Games.set_page_cleaned(doc.id, 0, "CLEANED", ["GARBLE: soup"])

      page = Games.get_document!(doc.id).pages |> Enum.find(&(&1.index == 0))
      assert page.cleaned == "CLEANED"
      assert page.cleanup_defects == ["GARBLE: soup"]
    end

    test "an empty defects list clears previously recorded defects", %{doc: doc} do
      {:ok, _} = Games.set_page_cleaned(doc.id, 0, "BAD", ["GARBLE: soup"])
      {:ok, _} = Games.set_page_cleaned(doc.id, 0, "GOOD", [])

      page = Games.get_document!(doc.id).pages |> Enum.find(&(&1.index == 0))
      assert page.cleanup_defects == []
    end

    test "the 3-arity form leaves cleanup_defects untouched", %{doc: doc} do
      {:ok, _} = Games.set_page_cleaned(doc.id, 0, "BAD", ["GARBLE: soup"])
      {:ok, _} = Games.set_page_cleaned(doc.id, 0, "edited by hand")

      page = Games.get_document!(doc.id).pages |> Enum.find(&(&1.index == 0))
      assert page.cleaned == "edited by hand"
      assert page.cleanup_defects == ["GARBLE: soup"]
    end
  end
end
