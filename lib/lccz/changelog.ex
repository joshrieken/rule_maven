defmodule Lccz.Changelog do
  @moduledoc """
  What's new (PLATFORM.md): CHANGELOG.md parsed (`Lccz.Changelog.Parser`) and who sees which notes.
  Everyone notes for all, Admins notes for admins only; the What's new mark shows while there's a
  release with notes for this reader newer than the one they last opened. Pure: each app keeps its
  releases (parsed at compile time) and records what each person has seen.
  """

  alias Lccz.Changelog.{Parser, Release}

  @doc "Parse CHANGELOG.md text, newest first."
  @spec parse(String.t()) :: [Release.t()]
  defdelegate parse(text), to: Parser

  @doc "Every release as this reader may see it: admins' notes only for admins (so some may be empty)."
  @spec reader_releases(boolean(), [Release.t()]) :: [Release.t()]
  def reader_releases(true, all), do: all
  def reader_releases(_, all), do: Enum.map(all, &%{&1 | admins: []})

  @doc "The releases with notes for this reader: what the What's new mark goes by."
  @spec visible_releases(boolean(), [Release.t()]) :: [Release.t()]
  def visible_releases(admin?, all),
    do: admin? |> reader_releases(all) |> Enum.filter(&(&1.everyone != [] or &1.admins != []))

  @doc "The newest version with notes for this reader, or nil."
  @spec newest_visible(boolean(), [Release.t()]) :: String.t() | nil
  def newest_visible(admin?, all) do
    case visible_releases(admin?, all) do
      [newest | _] -> newest.version
      [] -> nil
    end
  end

  @doc "Whether there's a release with notes for this reader newer than the one they last saw."
  @spec unseen?(boolean(), String.t() | nil, [Release.t()]) :: boolean()
  def unseen?(admin?, seen, all) do
    case newest_visible(admin?, all) do
      nil -> false
      newest -> newest != seen
    end
  end
end
