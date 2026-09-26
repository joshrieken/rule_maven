defmodule Mix.Tasks.RuleMaven.ImportPages do
  @moduledoc """
  Imports rulebooks transcribed outside the extraction pipeline (see
  `RuleMaven.ManualImport` for the JSON shape).

      mix rule_maven.import_pages GAME_ID path/to/doc.json [more.json …]

  Safe to run beside the dev server: the app starts with Oban's queues and
  plugins OFF, so this process only INSERTS jobs (embedding, cheat sheet) and the
  running server executes them. A second BEAM with live queues would steal the
  server's jobs and broadcast progress where no page is listening.
  """
  use Mix.Task

  @shortdoc "Import manually transcribed rulebook pages"

  @impl Mix.Task
  def run([game_id | files]) when files != [] do
    Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()
    game = RuleMaven.Games.get_game!(String.to_integer(game_id))

    for file <- files do
      attrs = file |> File.read!() |> Jason.decode!()

      case RuleMaven.ManualImport.import(game, attrs) do
        {:ok, doc} ->
          Mix.shell().info(
            "#{game.name}: imported \"#{doc.label}\" (#{length(doc.pages)} pages, doc #{doc.id})"
          )

        {:error, reason} ->
          Mix.raise("#{file}: #{inspect(reason)}")
      end
    end
  end

  def run(_), do: Mix.raise("usage: mix rule_maven.import_pages GAME_ID FILE.json [FILE.json …]")
end
