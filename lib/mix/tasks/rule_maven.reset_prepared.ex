defmodule Mix.Tasks.RuleMaven.ResetPrepared do
  @moduledoc """
  Wipes a game's PREPARED content so it can be rebuilt from scratch: every
  question & answer (and what hangs off them — votes, flags, favorites, tags,
  pool links), then `Games.reset_preparation/1` (rulebooks, chunks, PDFs on
  disk, readiness, every generated artifact) and the publish approval.

      mix rule_maven.reset_prepared GAME_ID [GAME_ID …]          # prompts
      mix rule_maven.reset_prepared GAME_ID [GAME_ID …] --yes    # no prompt

  Keeps the game row (catalog, BGG data, theme), users and llm_logs (the
  billing record). reset_preparation DELETES the uploaded PDFs — back them up
  first if they're needed again. Destructive and irreversible.
  """
  use Mix.Task

  import Ecto.Query

  alias RuleMaven.{Games, Readiness, Repo}
  alias RuleMaven.Games.QuestionLog

  @shortdoc "Delete a game's Q&A and prepared content"

  @impl Mix.Task
  def run(args) do
    {flags, ids} = Enum.split_with(args, &String.starts_with?(&1, "--"))

    if ids == [],
      do: Mix.raise("usage: mix rule_maven.reset_prepared GAME_ID [GAME_ID …] [--yes]")

    start_without_queues()
    games = Enum.map(ids, &Games.get_game!(String.to_integer(&1)))

    unless "--yes" in flags do
      names = Enum.map_join(games, ", ", & &1.name)

      if Mix.shell().prompt("Wipe Q&A and prepared content for #{names}? Type 'wipe': ")
         |> to_string()
         |> String.trim() != "wipe",
         do: Mix.raise("Aborted.")
    end

    for game <- games do
      {n, _} = Repo.delete_all(from q in QuestionLog, where: q.game_id == ^game.id)
      :ok = Games.reset_preparation(game)
      Readiness.revoke_publish(game)
      Readiness.stop_auto(game.id)
      Mix.shell().info("#{game.name}: #{n} Q&A deleted, preparation reset")
    end
  end

  @doc false
  # Start the app with Oban's queues and plugins OFF: this process may insert
  # jobs, but only the running server executes them. Every content task and
  # import-prepare script starts here, so this is also where dev refuses: prod
  # is the source of truth, and content written to dev never reaches users.
  def start_without_queues do
    refuse_dev_write!(Mix.env(), System.get_env("RULEMAVEN_DEV_WRITE"))
    conf = Application.get_env(:rule_maven, Oban, [])
    Application.put_env(:rule_maven, Oban, Keyword.merge(conf, queues: false, plugins: false))
    Mix.Task.run("app.start")
  end

  @doc false
  def refuse_dev_write!(:dev, override) when override != "1" do
    Mix.raise("""
    This writes to the DEV database, but production is the source of truth.
    Run it against prod instead: put bin/prod in front of the same command.
    To write to dev anyway (throwaway experiment): RULEMAVEN_DEV_WRITE=1 mix …
    """)
  end

  def refuse_dev_write!(_env, _override), do: :ok
end
