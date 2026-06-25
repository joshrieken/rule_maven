defmodule RuleMaven.GamesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `RuleMaven.Games` context.
  """

  @doc """
  Generate a game.
  """
  def game_fixture(attrs \\ %{}) do
    {:ok, game} =
      attrs
      |> Enum.into(%{
        bgg_id: 42,
        name: "some name"
      })
      |> RuleMaven.Games.create_game()

    game
  end

  @doc """
  Generate a game with a published rulebook document so it appears in the
  default "playable" view (which only lists games that have documents).
  """
  def published_game_fixture(attrs \\ %{}) do
    game = game_fixture(attrs)

    {:ok, _doc} =
      %RuleMaven.Games.Document{}
      |> RuleMaven.Games.Document.changeset(%{
        label: "Rulebook",
        full_text: "Test rulebook text.",
        game_id: game.id,
        status: "published"
      })
      |> RuleMaven.Repo.insert()

    game
  end
end
