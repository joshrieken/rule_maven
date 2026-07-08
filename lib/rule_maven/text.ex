defmodule RuleMaven.Text do
  @moduledoc """
  Small text hygiene helpers shared across extraction, RAG and rendering.
  """

  # Decorative icon glyphs the vision reader emits where a rulebook printed a
  # piece/marker icon or a fancy bullet: filled shapes (● ◧), map/piece symbols
  # (⛫ castle), stray emoji, and their variation selectors. They carry no
  # meaning in the extracted prose and only clutter answers, citations and
  # search. Deliberately conservative — arrows (→ ⇒), real bullets (•), dashes
  # and typographic quotes are meaningful and left alone.
  @decorative_glyphs ~r/[\x{25A0}-\x{25FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}\x{1F000}-\x{1FAFF}\x{FE0F}\x{200D}]/u

  @doc "True when `text` contains a decorative artifact glyph."
  def decorative?(text) when is_binary(text), do: Regex.match?(@decorative_glyphs, text)
  def decorative?(_), do: false

  @doc """
  Strips decorative extraction-artifact glyphs and tidies the whitespace they
  leave behind, without disturbing line structure. Idempotent; safe on nil.

  Collapses only horizontal runs of spaces/tabs (newlines are preserved so
  `pre-line` rendering and page markers survive) and drops a space stranded
  before closing punctuation once its glyph is gone (`"City ● Requires"` →
  `"City Requires"`, `"intersection ●."` → `"intersection."`).
  """
  def scrub_decorative(nil), do: nil

  def scrub_decorative(text) when is_binary(text) do
    text
    |> String.replace(@decorative_glyphs, "")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/[ \t]+([.,;:!?)\]])/, "\\1")
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n[ \t]+/, "\n")
  end
end
