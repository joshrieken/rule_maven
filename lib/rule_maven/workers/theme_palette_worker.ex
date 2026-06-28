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

  alias RuleMaven.{Games, LLM, ThemePalette}

  def topic(game_id), do: "theme:#{game_id}"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    status =
      case build_palette(game) do
        {:ok, palette} ->
          case Games.update_game(game, %{theme_palette: palette}) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        :skip ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:theme_palette, game_id, status})

    case status do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
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
