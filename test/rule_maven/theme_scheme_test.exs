defmodule RuleMaven.ThemeSchemeTest do
  @moduledoc """
  The picker groups themes into Light/Dark from the `scheme` tag in
  `Metrics.@themes`. That tag is hand-written, so it can silently disagree with
  the `color-scheme` the theme's CSS block actually declares — a theme filed
  under "Light" that paints itself dark. Pin the two together.
  """
  use ExUnit.Case, async: true

  alias RuleMaven.Metrics

  @css_path Path.join([File.cwd!(), "priv", "static", "assets", "css", "app.css"])

  # slug => :light | :dark, read out of `[data-theme="…"] { color-scheme: …; }`
  defp css_schemes do
    css = File.read!(@css_path)

    ~r/\[data-theme="([a-z-]+)"\]\s*\{[^}]*?color-scheme:\s*(light|dark)\s*;/
    |> Regex.scan(css)
    |> Map.new(fn [_, slug, scheme] -> {slug, String.to_existing_atom(scheme)} end)
  end

  test "every static theme declares the scheme it is grouped under" do
    css = css_schemes()

    for {scheme, entries} <- Metrics.themes_by_scheme(),
        {slug, _label} <- entries do
      assert css[slug] == scheme,
             "theme #{slug} is grouped as #{scheme} but its CSS says #{inspect(css[slug])}"
    end
  end

  test "themes_by_scheme partitions themes/0 — nothing dropped, nothing invented" do
    grouped =
      Metrics.themes_by_scheme()
      |> Enum.flat_map(fn {_scheme, entries} -> entries end)

    assert Enum.sort(grouped) == Enum.sort(Metrics.themes())
    assert length(grouped) == length(Metrics.themes())
  end

  test "both schemes are non-empty and light is offered first" do
    [{:light, light}, {:dark, dark}] = Metrics.themes_by_scheme()

    refute light == []
    refute dark == []
  end

  test "the light and dark defaults are themes of their own scheme" do
    by_scheme = Map.new(Metrics.themes_by_scheme())
    slugs = fn scheme -> by_scheme |> Map.fetch!(scheme) |> Enum.map(&elem(&1, 0)) end

    assert Metrics.default_theme(:light) in slugs.(:light)
    assert Metrics.default_theme(:dark) in slugs.(:dark)
  end
end
