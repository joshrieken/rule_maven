defmodule RuleMaven.Workers.BggEnrichWorker do
  @moduledoc """
  Durable BoardGameGeek enrichment. Previously `enrich_game(force: true)` ran
  synchronously inside the LiveView `handle_info`, blocking the whole LiveView
  process during the (throttled, retry-prone) BGG API call. This moves it to an
  Oban job that survives restarts and broadcasts `{:bgg_enriched, game_id,
  :ok | {:error, reason}}` on `topic/1` so the page can refresh when it lands.
  """
  use Oban.Worker,
    queue: :expansion,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query
  alias RuleMaven.Games

  def topic(game_id), do: "bgg:#{game_id}"

  @doc """
  Game ids with a BGG enrich job currently in flight. Lets a LiveView re-seed
  its "pulling…" indicator after a remount so the spinner survives navigation.
  """
  def running_game_ids do
    RuleMaven.Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "RuleMaven.Workers.BggEnrichWorker" and
            j.state in ["available", "scheduled", "executing", "retryable"],
        select: fragment("(?->>'game_id')::int", j.args)
    )
    |> MapSet.new()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    status =
      case RuleMaven.BGG.enrich_game(game, force: true) do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:bgg_enriched, game_id, status})

    case status do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
