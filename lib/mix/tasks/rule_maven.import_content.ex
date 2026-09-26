defmodule Mix.Tasks.RuleMaven.ImportContent do
  @moduledoc """
  Imports hand-authored Prepare content for a game from one JSON file:

      mix rule_maven.import_content GAME_ID USERNAME path/to/content.json

      {"enrichments": {…see RuleMaven.ManualImport.Enrichments…},
       "answers":     [{…see RuleMaven.ManualImport.Answers…}]}

  Answers are imported as ordinary answers owned by USERNAME. Like
  import_pages, runs with Oban queues OFF so the dev server executes any jobs.
  Categories and answers call the embedding API (the only paid step).
  """
  use Mix.Task

  import Ecto.Query

  alias Mix.Tasks.RuleMaven.ResetPrepared
  alias RuleMaven.{Games, Repo}
  alias RuleMaven.ManualImport.{Answers, Enrichments}
  alias RuleMaven.Users.User

  @shortdoc "Import hand-authored enrichments and answers"

  @impl Mix.Task
  def run([game_id, username, file]) do
    ResetPrepared.start_without_queues()
    game = Games.get_game!(String.to_integer(game_id))
    user = Repo.one!(from u in User, where: u.username == ^username)
    data = file |> File.read!() |> Jason.decode!()

    if enrichments = data["enrichments"] do
      case Enrichments.import(game, enrichments) do
        {:ok, steps} -> Mix.shell().info("#{game.name}: enrichments #{Enum.join(steps, ", ")}")
        {:error, reason} -> Mix.raise("enrichments: #{inspect(reason)}")
      end
    end

    if answers = data["answers"] do
      {:ok, r} = Answers.import(game, user, answers)

      Mix.shell().info(
        "#{game.name}: answers imported=#{r.imported} skipped=#{r.skipped} errors=#{length(r.errors)}"
      )

      for {q, reason} <- r.errors, do: Mix.shell().error("  ✗ #{q}: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix rule_maven.import_content GAME_ID USERNAME FILE.json")
end
