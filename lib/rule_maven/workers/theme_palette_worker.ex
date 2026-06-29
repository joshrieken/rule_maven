defmodule RuleMaven.Workers.ThemePaletteWorker do
  @moduledoc """
  Durable per-game theme generation. Given a game with a BGG cover image, asks
  the vision model for a small set of anchor colors, expands + contrast-guards
  them into a full light/dark CSS-variable palette (`RuleMaven.ThemePalette`),
  and stores it on `games.theme_palette`.

  Enqueued after a successful BGG enrich (when `image_url` first lands) and
  re-runnable on demand. Skips silently when the game has no cover. Broadcasts
  `{:theme_palette, game_id, :ok | {:error, reason}}` on `topic/1` so an open
  game page can offer the "Game-Specific" theme the moment it's ready.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable, :suspended]]

  import Ecto.Query
  alias RuleMaven.{Games, Jobs, LLM, ThemePalette}

  @worker "RuleMaven.Workers.ThemePaletteWorker"
  @active_states ~w(available scheduled executing retryable)

  def topic(game_id), do: "theme:#{game_id}"

  @doc "True when theme generation for this game is queued or running (survives a refresh)."
  def running?(game_id) do
    RuleMaven.Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("theme_palette", {"game", game_id}, "Theme palette — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Deriving a colour palette from the cover image…")

    status =
      case build_palette(game) do
        {:ok, palette} ->
          case Games.update_game(game, %{theme_palette: palette}) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        :skip ->
          :skip

        {:error, reason} ->
          {:error, reason}
      end

    case status do
      :ok -> Jobs.finish_run(run, "done", "Palette generated.")
      :skip -> Jobs.finish_run(run, "done", "Skipped — no cover image.")
      {:error, reason} -> Jobs.finish_run(run, "failed", inspect(reason))
    end

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      topic(game_id),
      {:theme_palette, game_id, if(status == :skip, do: :ok, else: status)}
    )

    case status do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp build_palette(%{name: name, image_url: url}) when is_binary(url) and url != "" do
    with {:ok, anchors} <- LLM.generate_theme_palette(name, url),
         {:ok, palette} <- ThemePalette.build(anchors) do
      {:ok, palette}
    end
  end

  defp build_palette(_), do: :skip

  @doc "Enqueue palette generation for a game that has a cover image."
  def enqueue(%{id: id, image_url: url}) when is_binary(url) and url != "" do
    %{game_id: id} |> new() |> Oban.insert()
  end

  def enqueue(_), do: {:ok, :no_image}
end
