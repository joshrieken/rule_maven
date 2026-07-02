defmodule RuleMaven.Workers.DownloadWorkerUniquenessTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games
  alias RuleMaven.Workers.DownloadWorker

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual —
  # see config/test.exs), but `Oban.insert/2`'s unique-conflict check needs a
  # named, configured instance to query against. Start a queueless/pluginless
  # one scoped to this test so the insert path (including uniqueness) runs for
  # real against the sandboxed connection.
  setup do
    name = :"Oban#{System.unique_integer([:positive])}"

    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: name, testing: :disabled, queues: false, plugins: false}
    )

    {:ok, oban_name: name}
  end

  defp count_jobs(game_id) do
    import Ecto.Query

    RuleMaven.Repo.aggregate(
      from(j in Oban.Job,
        where: j.worker == "RuleMaven.Workers.DownloadWorker",
        where: fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
      ),
      :count
    )
  end

  test "distinct modes for the same game both enqueue (no cross-mode coalescing)", %{
    oban_name: oban_name
  } do
    {:ok, game} = Games.create_game(%{name: "DL uniq #{System.unique_integer([:positive])}"})

    {:ok, _} =
      %{game_id: game.id, mode: "find", url: nil, label: ""}
      |> DownloadWorker.new()
      |> then(&Oban.insert(oban_name, &1))

    {:ok, _} =
      %{game_id: game.id, mode: "upload", files: []}
      |> DownloadWorker.new()
      |> then(&Oban.insert(oban_name, &1))

    assert count_jobs(game.id) == 2
  end

  test "same mode + same args still coalesces (duplicate-protection preserved)", %{
    oban_name: oban_name
  } do
    {:ok, game} = Games.create_game(%{name: "DL uniq #{System.unique_integer([:positive])}"})

    {:ok, job1} =
      %{game_id: game.id, mode: "find", url: nil, label: ""}
      |> DownloadWorker.new()
      |> then(&Oban.insert(oban_name, &1))

    {:ok, job2} =
      %{game_id: game.id, mode: "find", url: nil, label: ""}
      |> DownloadWorker.new()
      |> then(&Oban.insert(oban_name, &1))

    assert job1.id == job2.id
    assert count_jobs(game.id) == 1
  end
end
