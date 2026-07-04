defmodule Mix.Tasks.RuleMaven.BackfillWeight do
  @shortdoc "Backfill BGG complexity weight for existing games from cached XML"
  @moduledoc """
  Reparses each game's already-cached BGG XML (`bgg_data`) to extract the
  `averageweight` complexity rating, without calling the BGG API again.
  Skips games that already have `weight` set or have no cached XML.

      mix rule_maven.backfill_weight
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Repo, Games, BGG}
  alias RuleMaven.Games.Game

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    games =
      Repo.all(
        from g in Game,
          where: is_nil(g.weight) and not is_nil(g.bgg_data)
      )

    if games == [] do
      Mix.shell().info("No games need weight backfill.")
    else
      Mix.shell().info("Backfilling weight for #{length(games)} games...")

      Enum.each(games, fn game ->
        case BGG.extract_weight(game.bgg_data) do
          nil ->
            :ok

          weight ->
            {:ok, _} = Games.update_game(game, %{weight: weight})
            Mix.shell().info("  #{game.name}: weight=#{weight}")
        end
      end)

      Mix.shell().info("Done.")
    end
  end
end
