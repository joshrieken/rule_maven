defmodule RuleMavenWeb.CoreComponents.CitationCardsTest do
  @moduledoc """
  The quote box preserves the quote's own line breaks (`pre-line`). That style
  must sit on a tight wrapper around the quote text only — on the blockquote it
  turned the template's indentation newline into a blank line above every quote.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RuleMavenWeb.CoreComponents, only: [citation_cards: 1]

  defp cards(q), do: render_component(&citation_cards/1, q: q)

  test "no whitespace-preserving element starts with a newline" do
    html =
      cards(%{
        citations: [
          %{
            "quote" => "Any time a new party is formed, that party starts at 0 reputation.",
            "page" => 42,
            "source" => "Rulebook"
          }
        ]
      })

    refute html =~ ~r/<blockquote[^>]*pre-line/
    assert html =~ ~r/pre-line[^>]*>Any time a new party/
  end

  test "line breaks inside a quote are still preserved" do
    html =
      cards(%{
        citations: [%{"quote" => "Roll both dice at the start of your turn.\nThen move your pawn that many spaces.", "page" => 3, "source" => "Rulebook"}]
      })

    assert html =~ ~r/pre-line[^>]*>Roll both dice at the start of your turn.\nThen move your pawn/
  end
end
