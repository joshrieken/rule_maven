defmodule RuleMavenWeb.CoreComponents.CitationPagesTest do
  use ExUnit.Case, async: true

  import RuleMavenWeb.CoreComponents, only: [citation_pages: 1, citation_chip: 1]

  test "lists every cited page, ascending" do
    q = %{
      citations: [
        %{"quote" => "b", "page" => 11, "source" => "Core Rulebook"},
        %{"quote" => "a", "page" => 5, "source" => "Core Rulebook"}
      ]
    }

    assert citation_pages(q) == [5, 11]
  end

  test "dedupes pages shared by several quotes" do
    q = %{
      citations: [
        %{"quote" => "a", "page" => 5, "source" => "Core Rulebook"},
        %{"quote" => "b", "page" => 5, "source" => "Core Rulebook"}
      ]
    }

    assert citation_pages(q) == [5]
  end

  test "drops pageless citations" do
    q = %{citations: [%{"quote" => "a", "page" => nil, "source" => "Core Rulebook"}]}

    assert citation_pages(q) == []
  end

  test "falls back to the legacy scalar columns" do
    q = %{citations: [], cited_passage: "a", cited_page: 7, cited_source: "Core Rulebook"}

    assert citation_pages(q) == [7]
  end

  test "no citations at all" do
    assert citation_pages(%{citations: []}) == []
  end

  describe "citation_chip/1" do
    test "names each cited source with its pages, in citation order" do
      q = %{
        citations: [
          %{"quote" => "a", "page" => 4, "source" => "Rulebook"},
          %{"quote" => "b", "page" => 2, "source" => "Official FAQ (catan.com)"},
          %{"quote" => "c", "page" => 9, "source" => "Rulebook"}
        ]
      }

      assert citation_chip(q) == "Rulebook p.4, 9 · Official FAQ (catan.com) p.2"
    end

    test "a missing source reads as Rulebook; long labels are shortened" do
      q = %{
        citations: [
          %{"quote" => "a", "page" => 3, "source" => nil},
          %{
            "quote" => "b",
            "page" => 1,
            "source" => "Championship Tournament Rules 2023 (tournament play only)"
          }
        ]
      }

      assert citation_chip(q) == "Rulebook p.3 · Championship Tournament… p.1"
    end

    test "nil when nothing has a page" do
      assert citation_chip(%{
               citations: [%{"quote" => "a", "page" => nil, "source" => "Rulebook"}]
             }) == nil

      assert citation_chip(%{citations: []}) == nil
    end
  end
end
