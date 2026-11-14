defmodule RuleMavenWeb.SymbolMarkup do
  @moduledoc """
  Shows the symbol key inline: rewrites known symbol tokens
  ("[purple hammer symbol]") in already-rendered answer / citation HTML into
  a chip with the book's cropped icon and name.

  `marks/1` precomputes one matcher per symbol from the Symbols tool's
  `symbol_groups` (so the per-render cost is regex runs, not compiles);
  `decorate/2` rewrites only TEXT between tags, never attributes. A token
  whose game has icons switched off (or that has no crop) keeps its text,
  gaining a hover title with the book's name. Unknown tokens are untouched.
  """

  use RuleMavenWeb, :verified_routes

  alias RuleMaven.Hashid

  @doc "Matchers for `decorate/2`, longest token first, base game before expansions on ties."
  def marks(symbol_groups) do
    for(g <- symbol_groups, s <- g.symbols, do: {s, g.images?})
    |> Enum.with_index()
    |> Enum.sort_by(fn {{s, _}, i} -> {-String.length(s.token), i} end)
    |> Enum.map(fn {{s, images?}, _} ->
      %{
        regex: html_token_regex(s.token),
        fills: fill_templates(s.token),
        symbol: s,
        icon?: images? and not is_nil(s.image_path)
      }
    end)
  end

  @doc "Rewrites tokens in `html` (a binary of rendered, escaped HTML)."
  def decorate(html, []), do: html

  def decorate(html, marks) do
    ~r/(<[^>]*>)/
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(fn
      "<" <> _ = tag -> tag
      text -> decorate_text(text, marks)
    end)
  end

  # Two passes: each match first becomes a placeholder `\0<mark index>\1<text>\0`
  # (no "[" left for a later, shorter token to re-match), then placeholders
  # expand to chips — whose titles may themselves quote tokens.
  defp decorate_text(text, marks) do
    marked =
      marks
      |> Enum.with_index()
      |> Enum.reduce(text, fn {mark, i}, acc ->
        Regex.replace(mark.regex, acc, fn whole ->
          "\0#{i}\x01#{String.replace(whole, "[", "\x02")}\0"
        end)
      end)

    Regex.replace(~r/\x00(\d+)\x01([^\x00]*)\x00/, marked, fn _, i, whole ->
      chip(Enum.at(marks, String.to_integer(i)), String.replace(whole, "\x02", "["))
    end)
  end

  defp chip(%{symbol: s, icon?: true} = mark, whole) do
    label = fill_label(mark, whole) || s.name

    ~s(<span class="sym-mark" title="#{esc(title(s))}">) <>
      ~s(<img class="sym-icon" src="#{~p"/symbols/#{Hashid.encode(s.id)}/image"}" alt="#{esc(s.name || strip(s.token))}" loading="lazy">) <>
      if(label, do: ~s(<span class="sym-label">#{esc(label)}</span>), else: "") <>
      "</span>"
  end

  defp chip(%{symbol: %{name: nil}}, whole), do: whole

  defp chip(%{symbol: s}, whole),
    do: ~s(<span class="sym-mark sym-mark-text" title="#{esc(title(s))}">#{whole}</span>)

  defp title(s), do: Enum.join(Enum.reject([s.name, s.meaning], &is_nil/1), " — ")

  # A numeric family ("[black triangle: {n}]") shows its number(s) beside the
  # icon, keeping an adjacent "+" ("{n}+", "+{n}").
  defp fill_label(%{fills: []}, _whole), do: nil

  defp fill_label(%{fills: fills, regex: regex}, whole) do
    # `whole` matched this regex already, so the run cannot fail.
    [_ | nums] = Regex.run(regex, whole)

    fills
    |> Enum.zip(nums)
    |> Enum.map_join(" ", fn {tpl, n} -> String.replace(tpl, "{n}", n) end)
  end

  defp fill_templates(token),
    do: Regex.scan(~r/\+?\{n\}\+?/, token) |> List.flatten()

  # The token as it appears in HTML-escaped text; `{n}` captures a number.
  defp html_token_regex(token) do
    token
    |> html_escape_text()
    |> String.split("{n}")
    |> Enum.map_join("(\\d+)", &Regex.escape/1)
    |> Regex.compile!("iu")
  end

  defp html_escape_text(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp strip(token), do: token |> String.trim_leading("[") |> String.trim_trailing("]")

  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
