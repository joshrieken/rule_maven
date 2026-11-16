defmodule RuleMaven.Changelog do
  @moduledoc """
  The app's version (VERSION, via mix.exs) and its release notes (CHANGELOG.md, parsed at
  compile time). Each release has notes for everyone and notes only admins see; readers only
  ever get the sections their role allows (`reader_releases/2`).

  The "What's new" mark: a user's `seen_version` is the newest release with notes for them
  that they've opened /changelog since. `unseen?/3` is true while a newer one exists.
  """

  alias RuleMaven.Changelog.{Parser, Release}
  alias RuleMaven.Users
  alias RuleMaven.Users.User

  @path Path.expand("../../CHANGELOG.md", __DIR__)
  @external_resource @path

  @releases (case File.read(@path) do
               {:ok, text} -> Parser.parse(text)
               {:error, _} -> []
             end)

  @doc "Parse CHANGELOG.md text (see `RuleMaven.Changelog.Parser`)."
  @spec parse(String.t()) :: [Release.t()]
  defdelegate parse(text), to: Parser

  @doc "Every release, newest first (CHANGELOG.md as of compile time)."
  @spec releases() :: [Release.t()]
  def releases, do: @releases

  @doc "The running app's version, e.g. \"0.1.5\"."
  @spec app_version() :: String.t()
  def app_version, do: to_string(Application.spec(:rule_maven, :vsn))

  @doc "Every release as this reader may see it: admins' notes only for admins (so some may be empty)."
  @spec reader_releases(boolean(), [Release.t()]) :: [Release.t()]
  def reader_releases(admin?, all \\ releases())
  def reader_releases(true, all), do: all
  def reader_releases(_, all), do: Enum.map(all, &%{&1 | admins: []})

  @doc "The releases with notes for this reader: what the \"What's new\" mark goes by."
  @spec visible_releases(boolean(), [Release.t()]) :: [Release.t()]
  def visible_releases(admin?, all \\ releases()) do
    admin? |> reader_releases(all) |> Enum.filter(&(&1.everyone != [] or &1.admins != []))
  end

  @doc "Whether there's a release with notes for this reader newer than the one they last saw."
  @spec unseen?(boolean(), String.t() | nil, [Release.t()]) :: boolean()
  def unseen?(admin?, seen, all \\ releases()) do
    case visible_releases(admin?, all) do
      [newest | _] -> newest.version != seen
      [] -> false
    end
  end

  @doc "Whether this user (nil = signed out: never) has release notes they haven't opened."
  @spec unseen_for?(User.t() | nil, [Release.t()]) :: boolean()
  def unseen_for?(user, all \\ releases())
  def unseen_for?(nil, _all), do: false

  def unseen_for?(%User{} = user, all),
    do: unseen?(Users.can?(user, :admin), user.seen_version, all)

  @doc """
  Records that this user has seen the newest release with notes for them. Returns the user
  unchanged when there's nothing newer (or no user), so a page view only writes when it matters.
  """
  @spec mark_seen(User.t() | nil, [Release.t()]) ::
          {:ok, User.t() | nil} | {:error, Ecto.Changeset.t()}
  def mark_seen(user, all \\ releases())
  def mark_seen(nil, _all), do: {:ok, nil}

  def mark_seen(%User{} = user, all) do
    case visible_releases(Users.can?(user, :admin), all) do
      [%Release{version: v} | _] when v != user.seen_version -> Users.mark_version_seen(user, v)
      _ -> {:ok, user}
    end
  end
end
