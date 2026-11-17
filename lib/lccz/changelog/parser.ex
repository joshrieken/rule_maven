defmodule Lccz.Changelog.Parser do
  @moduledoc """
  CHANGELOG.md's format, parsed. Its own module (no app dependencies) so
  each app can run it at compile time.

      ## vX.Y.Z (YYYY-MM-DD)
      ### Everyone
      - A bullet, which may continue
        on indented lines.
      ### Admins
      - ...

  Lenient: the older `## vX.Y.Z — YYYY-MM-DD` heading and a dateless `## X.Y.Z` also count;
  other `##` headings (e.g. `## Unreleased`) and anything under them are skipped; bullets under
  an unknown `###` section (or none) are dropped rather than shown to everyone.
  """

  alias Lccz.Changelog.Release

  @release_re ~r/^##\s+v?(\d+\.\d+\.\d+)(?:\s*(?:\(|—|–|-)\s*(\d{4}-\d{2}-\d{2})\)?)?\s*$/u
  @section_re ~r/^###\s+(.+?)\s*$/
  @bullet_re ~r/^\s*[-*]\s+(.+?)\s*$/

  @doc "Parse CHANGELOG.md text into releases, newest (first in the file) first."
  @spec parse(String.t()) :: [Release.t()]
  def parse(text) when is_binary(text) do
    {releases, _section} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, &parse_line/2)

    releases
    |> Enum.reject(&(&1 == :skip))
    |> Enum.reverse()
    |> Enum.map(&%{&1 | everyone: Enum.reverse(&1.everyone), admins: Enum.reverse(&1.admins)})
  end

  defp parse_line(raw, {releases, section}) do
    line = String.trim_trailing(raw)

    cond do
      match = Regex.run(@release_re, line) ->
        {[new_release(match) | releases], nil}

      line == "##" or String.starts_with?(line, "## ") ->
        # Unreleased or anything else that isn't a version: its notes belong to no release.
        {[:skip | releases], nil}

      match = Regex.run(@section_re, line) ->
        {releases, section_key(Enum.at(match, 1))}

      true ->
        {add_item(releases, line, section), section}
    end
  end

  defp new_release([_, version]), do: %Release{version: version}
  defp new_release([_, version, date]), do: %Release{version: version, date: parse_date(date)}

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp section_key(name) do
    case String.downcase(name) do
      "everyone" -> :everyone
      "admins" -> :admins
      _ -> nil
    end
  end

  defp add_item([%Release{} = current | rest] = releases, line, section)
       when section in [:everyone, :admins] do
    items = Map.fetch!(current, section)

    cond do
      match = Regex.run(@bullet_re, line) ->
        [Map.put(current, section, [Enum.at(match, 1) | items]) | rest]

      continuation?(line) and items != [] ->
        [last | earlier] = items
        [Map.put(current, section, [last <> " " <> String.trim(line) | earlier]) | rest]

      true ->
        releases
    end
  end

  defp add_item(releases, _line, _section), do: releases

  # An indented, non-blank line that isn't a new bullet continues the bullet above it.
  defp continuation?(line), do: String.trim(line) != "" and Regex.match?(~r/^\s/, line)
end
