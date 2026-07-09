defmodule RuleMavenWeb.CoreComponents.CitationPagesTest do
  use ExUnit.Case, async: true

  import RuleMavenWeb.CoreComponents, only: [citation_pages: 1]

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
end
