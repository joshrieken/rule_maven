defmodule RuleMavenWeb.CoreComponents.CitationCardsTest do
  @moduledoc """
  The quote box preserves the quote's own line breaks (`pre-line`). That style
  must sit on a tight wrapper around the quote text only — on the blockquote it
  turned the template's indentation newline into a blank line above every quote.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RuleMavenWeb.CoreComponents, only: [citation_cards: 1]

  alias RuleMaven.Symbols.Symbol
  alias RuleMavenWeb.SymbolMarkup

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
        citations: [
          %{
            "quote" =>
              "Roll both dice at the start of your turn.\nThen move your pawn that many spaces.",
            "page" => 3,
            "source" => "Rulebook"
          }
        ]
      })

    assert html =~
             ~r/pre-line[^>]*>Roll both dice at the start of your turn.\nThen move your pawn/
  end

  describe "symbol chips" do
    defp marks do
      SymbolMarkup.marks([
        %{
          name: "G",
          images?: true,
          symbols: [
            %Symbol{
              id: 7,
              token: "[black crescent moon symbol]",
              name: "Open box",
              meaning: nil,
              image_path: "symbols/x.png"
            }
          ]
        }
      ])
    end

    @quote "Have a party reputation of -10 or lower – open box [black crescent moon symbol] now.\nThen read on."

    test "tokens in a quote become chips when marks are given" do
      html =
        render_component(&citation_cards/1,
          q: %{citations: [%{"quote" => @quote, "page" => 49, "source" => "Rulebook"}]},
          symbol_marks: marks()
        )

      assert html =~ ~s(<span class="sym-label">Open box</span>)
      refute html =~ "[black crescent moon symbol]"
      assert html =~ "now.\nThen read on."
    end

    test "without marks the token text is left as is (and still escaped)" do
      html =
        render_component(&citation_cards/1,
          q: %{
            citations: [
              %{
                "quote" => "A <b> [black crescent moon symbol]",
                "page" => 1,
                "source" => "Rulebook"
              }
            ]
          }
        )

      assert html =~ "[black crescent moon symbol]"
      assert html =~ "A &lt;b&gt;"
    end
  end
end
