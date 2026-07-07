defmodule RuleMaven.Workers.VoiceVetWorker do
  @moduledoc """
  Backfill style vetting for a game's already-generated persona voices.

  New voices are vetted inside `VoiceSuggestionsWorker`; this worker covers
  voices generated before vetting existed (or whose vet call failed there).
  AskWorker enqueues it lazily the first time an unvetted generated voice is
  used, so that ask still takes the restyle path but subsequent ones get the
  single-call persona path. Slugs that fail the vet stay `vetted: false`
  forever — that's the safe steady state, not an error.

  `unique` per game so a burst of asks enqueues one job.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Jobs, Voices}

  @doc "Enqueue a vet backfill (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if oban_running?() do
      %{game_id: game_id} |> new() |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    case Voices.unvetted_generated(game_id) do
      [] ->
        :ok

      unvetted ->
        run =
          Jobs.start_run("voices", {"game", game_id}, "Persona style vet backfill",
            oban_job_id: oban_id
          )

        case RuleMaven.LLM.vet_voice_styles(unvetted, game_id: game_id) do
          {:ok, safe_slugs} ->
            Voices.mark_vetted(game_id, safe_slugs)

            Jobs.finish_run(
              run,
              "done",
              "#{length(safe_slugs)}/#{length(unvetted)} styles safe for the single-call ask path."
            )

            :ok

          {:error, reason} ->
            Jobs.finish_run(run, "failed", inspect(reason))
            {:error, reason}
        end
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
