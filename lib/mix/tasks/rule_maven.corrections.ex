defmodule Mix.Tasks.RuleMaven.Corrections do
  @shortdoc "List answers awaiting review, or apply corrections/upholds"

  @moduledoc """
  The wrong-answer review loop (see `RuleMaven.ManualImport.Corrections`).

      mix rule_maven.corrections list [GAME_ID] > queue.json
      mix rule_maven.corrections apply USERNAME FILE.json

  `list` prints the queue as JSON (question id, game id + name, text,
  answer, citations, expansion ids, flag reasons, thumbs-down). `apply` takes
  `{"corrections": [{"question": ID, "action": "correct", "answer", "verdict",
  "citations": [{"quote", "page"}], "note"} | {"question": ID, "action":
  "uphold", "note"}]}`. Runs with Oban queues OFF so the dev server runs jobs.
  """
  use Mix.Task

  alias Mix.Tasks.RuleMaven.ResetPrepared
  alias RuleMaven.Repo
  alias RuleMaven.ManualImport.Corrections
  alias RuleMaven.Users.User

  @impl Mix.Task
  def run(["list" | rest]) do
    # Dev logs SQL to stdout; keep it out of the JSON this prints.
    Logger.configure(level: :warning)
    ResetPrepared.start_without_queues()
    opts = if rest == [], do: [], else: [game_id: String.to_integer(hd(rest))]
    queue = Corrections.queue(opts)
    names = Corrections.game_names(queue)
    entries = Enum.map(queue, &Corrections.entry_payload(&1, names, fn id -> id end))

    IO.puts(Jason.encode!(%{queue: entries}, pretty: true))
  end

  def run(["apply", username, file]) do
    ResetPrepared.start_without_queues()
    actor = Repo.get_by!(User, username: username)
    %{"corrections" => entries} = file |> File.read!() |> Jason.decode!()

    for {id, result} <- Corrections.apply_all(entries, actor) do
      case result do
        :ok -> Mix.shell().info("✓ #{id}")
        {:error, reason} -> Mix.shell().error("✗ #{id}: #{inspect(reason)}")
      end
    end
  end

  def run(_),
    do: Mix.raise("usage: mix rule_maven.corrections list [GAME_ID] | apply USERNAME FILE.json")
end
