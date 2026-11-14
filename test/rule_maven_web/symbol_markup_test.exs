defmodule RuleMavenWeb.SymbolMarkupTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Hashid
  alias RuleMaven.Symbols.Symbol
  alias RuleMavenWeb.SymbolMarkup

  defp sym(id, token, attrs \\ []) do
    struct(
      %Symbol{id: id, token: token, name: nil, meaning: nil, image_path: "symbols/x.png"},
      attrs
    )
  end

  defp marks(symbols, images? \\ true),
    do: SymbolMarkup.marks([%{name: "G", images?: images?, symbols: symbols}])

  test "a known token becomes an icon chip with the book's name" do
    m = marks([sym(1, "[purple hammer symbol]", name: "Blacksmith", meaning: "A class.")])
    out = SymbolMarkup.decorate("<p>Spend a [Purple Hammer symbol] now.</p>", m)

    assert out =~ ~s(src="/symbols/#{Hashid.encode(1)}/image")
    assert out =~ ~s(title="Blacksmith — A class.")
    assert out =~ ~s(<span class="sym-label">Blacksmith</span>)
    refute out =~ "hammer symbol]"
    assert out =~ "<p>Spend a <span"
  end

  test "a numeric family shows its number, keeping an adjacent +" do
    m = marks([sym(2, "[blue circle token: {n}+]", name: "Magic item")])
    out = SymbolMarkup.decorate("<p>Needs [blue circle token: 3+].</p>", m)

    assert out =~ ~s(<span class="sym-label">3+</span>)
  end

  test "icons off keeps the token text, adding a hover title; unnamed stays untouched" do
    m = marks([sym(3, "[road piece]", name: "Road"), sym(4, "[odd glyph]")], false)
    out = SymbolMarkup.decorate("<p>[road piece] and [odd glyph]</p>", m)

    assert out =~ ~s(<span class="sym-mark sym-mark-text" title="Road">[road piece]</span>)
    assert out =~ "and [odd glyph]</p>"
    refute out =~ "<img"
  end

  test "never rewrites inside a tag, and a title quoting another token is not re-matched" do
    m =
      marks([
        sym(5, "[gold coin]", name: "Coin", meaning: "Pay with [silver coin]."),
        sym(6, "[silver coin]", name: "Silver")
      ])

    out = SymbolMarkup.decorate(~s(<a href="/x?[gold coin]">[gold coin]</a>), m)

    assert out =~ ~s(href="/x?[gold coin]")
    assert out =~ ~s(title="Coin — Pay with [silver coin].")
    assert length(Regex.scan(~r/<img/, out)) == 1
  end

  test "no marks is a no-op" do
    assert SymbolMarkup.decorate("<p>[x]</p>", []) == "<p>[x]</p>"
  end
end
