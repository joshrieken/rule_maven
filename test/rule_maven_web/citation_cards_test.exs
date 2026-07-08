defmodule RuleMavenWeb.CitationCardsTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMavenWeb.CoreComponents

  defp render_cards(q), do: render_component(&citation_cards/1, %{q: q})

  test "splits a newline-delimited leading heading into a bolded head" do
    html =
      render_cards(%{
        citations: [
          %{
            "quote" => "1. Resource Production\nYou begin your turn by rolling both dice.",
            "page" => 3,
            "source" => "Catan Base"
          }
        ]
      })

    assert html =~ "<strong"
    assert html =~ "1. Resource Production"
    assert html =~ "You begin your turn by rolling both dice."
  end

  test "splits a glued inline structural heading with no newline" do
    html =
      render_cards(%{
        citations: [
          %{
            "quote" =>
              "Round Two Once all players have built their first settlement, the player who went last begins round two.",
            "page" => 2,
            "source" => "Catan Base"
          }
        ]
      })

    assert html =~ "<strong"
    assert html =~ ">Round Two</strong>"
    assert html =~ "Once all players have built"
    # the heading text is not duplicated inside the body
    refute html =~ "Round Two Once all players"
  end

  test "does not invent a heading from an ordinary sentence" do
    html =
      render_cards(%{
        citations: [
          %{
            "quote" => "Players take turns in clockwise order until someone wins.",
            "page" => 5,
            "source" => "Catan Base"
          }
        ]
      })

    refute html =~ "<strong"
    assert html =~ "Players take turns in clockwise order"
  end

  test "renders the source and page header, page as its own element" do
    html = render_cards(%{citations: [%{"quote" => "Some rule.", "page" => 7, "source" => "Ticket to Ride"}]})

    assert html =~ "Ticket to Ride"
    assert html =~ "p.7"
  end

  test "quotes sharing a page render as separate blocks, not joined by an ellipsis" do
    html =
      render_cards(%{
        citations: [
          %{"quote" => "First rule about setup.", "page" => 1, "source" => "Catan Base"},
          %{"quote" => "Second rule about setup.", "page" => 1, "source" => "Catan Base"}
        ]
      })

    assert html =~ "First rule about setup."
    assert html =~ "Second rule about setup."
    refute html =~ "…"
    # one card (one figcaption), two blockquotes
    assert length(String.split(html, "<figcaption")) == 2
    assert length(String.split(html, "<blockquote")) == 3
  end

  test "falls back to legacy cited_passage fields" do
    html =
      render_cards(%{cited_passage: "Legacy passage text.", cited_page: 9, cited_source: "Old Book"})

    assert html =~ "Legacy passage text."
    assert html =~ "p.9"
    assert html =~ "Old Book"
  end
end
