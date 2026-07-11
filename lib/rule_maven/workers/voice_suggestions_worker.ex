defmodule RuleMaven.Workers.VoiceSuggestionsWorker do
  @moduledoc """
  Durable generation of per-game persona voices from a game's rulebook/theme.
  Writes the result to `game_voices` via `Voices.replace_generated/2` (stable
  slugs keep already-paid restyle caches) and broadcasts `{:voices_ready, defs}`
  on `topic/1` so a mounted show page swaps in the game's themed voices live.

  Mirrors `DidYouKnowWorker`: `unique` per game, survives restarts, no-op in
  test where Oban isn't supervised.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  alias RuleMaven.{Games, Jobs, Voices}

  @worker "RuleMaven.Workers.VoiceSuggestionsWorker"
  @active_states ~w(available scheduled executing retryable suspended)

  def topic(game_id), do: "game_voices:#{game_id}"

  @doc "True when voice generation for this game is queued or running."
  def running?(game_id) do
    RuleMaven.Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
    )
  end

  @doc "Enqueue voice generation (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if oban_running?() do
      %{game_id: game_id} |> new() |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)
    text = Games.document_full_text(game)

    run =
      Jobs.start_run("voices", {"game", game_id}, "Game voices — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Reading #{String.length(text)} chars to theme persona voices…")

    case RuleMaven.LLM.generate_voices(game.name, text) do
      {:ok, voices} when voices != [] ->
        # The vet gates the single-call persona path (style inlined into the
        # ask prompt) AND flags real-person personas, which are dropped before
        # they're ever stored. A vet failure isn't fatal — voices land
        # unvetted and keep the restyle path; VoiceVetWorker retries the vet
        # lazily (including the real-person purge) on the next ask that uses
        # one of them.
        voices =
          case RuleMaven.LLM.vet_voice_styles(voices, game_id: game_id) do
            {:ok, %{safe: safe_slugs, real_person: real_person_slugs}} ->
              flagged = MapSet.new(real_person_slugs)

              if MapSet.size(flagged) > 0 do
                Jobs.event(
                  run,
                  :warn,
                  "Dropped #{MapSet.size(flagged)} real-person persona(s): #{Enum.join(real_person_slugs, ", ")}."
                )
              end

              safe = MapSet.new(safe_slugs)
              voices = Enum.reject(voices, &MapSet.member?(flagged, &1.slug))

              Jobs.event(
                run,
                :info,
                "Style vet: #{MapSet.size(safe)}/#{length(voices)} safe for the single-call ask path."
              )

              Enum.map(voices, &Map.put(&1, :vetted, MapSet.member?(safe, &1.slug)))

            {:error, reason} ->
              Jobs.event(
                run,
                :warn,
                "Style vet failed (#{inspect(reason)}) — all voices take the restyle path for now."
              )

              voices
          end

        Voices.replace_generated(game_id, voices)
        defs = Voices.for_game(game_id)

        Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:voices_ready, defs})

        Jobs.finish_run(run, "done", "#{length(voices)} themed voices.")
        :ok

      {:ok, []} ->
        # Thin rulebook / nothing themed; leave the globals as the only voices.
        Jobs.finish_run(run, "done", "No themed voices generated.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
