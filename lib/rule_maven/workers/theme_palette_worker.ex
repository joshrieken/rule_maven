defmodule RuleMaven.Workers.ThemePaletteWorker do
  @moduledoc """
  Durable per-game theme generation. Given a game with a BGG cover image, asks
  the vision model for a small set of anchor colors, expands + contrast-guards
  them into a full light/dark CSS-variable palette (`RuleMaven.ThemePalette`),
  and stores it on `games.theme_palette`.

  The same call names the two variants after the game's world (e.g. "Harbor
  Daylight" / "Longest Night"); the names land on `games.theme_names` and label
  the game options in the theme picker. Names are cosmetic — an unusable one
  never fails an otherwise good palette, it just falls back to "Game Light".

  Enqueued after a successful BGG enrich (when `image_url` first lands) and
  re-runnable on demand. Skips silently when the game has no cover. Broadcasts
  `{:theme_palette, game_id, :ok | {:error, reason}}` on `topic/1` so an open
  game page can offer the "Game-Specific" theme the moment it's ready.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

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
        {:ok, palette, names} ->
          attrs = %{theme_palette: palette}
          attrs = if names, do: Map.put(attrs, :theme_names, names), else: attrs

          case Games.update_game(game, attrs) do
            {:ok, _} -> {:ok, palette, names}
            {:error, reason} -> {:error, reason}
          end

        :skip ->
          :skip

        {:error, reason} ->
          {:error, reason}
      end

    case status do
      {:ok, palette, names} ->
        Jobs.finish_run(
          run,
          "done",
          "Palette generated (#{map_size(palette)} variants). #{name_summary(names)}"
        )

      :skip ->
        Jobs.finish_run(run, "done", "Skipped — no cover image.")

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
    end

    # Subscribers only care about success vs failure — collapse the success
    # payload (which now carries the palette for the job summary) back to :ok.
    result =
      case status do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      topic(game_id),
      {:theme_palette, game_id, result}
    )

    result
  end

  defp build_palette(%{id: id, name: name, image_url: url}) when is_binary(url) and url != "" do
    with {:ok, anchors} <- LLM.generate_theme_palette(name, url, id),
         {:ok, palette} <- ThemePalette.build(anchors) do
      # Names are cosmetic: a model that returns junk (or nothing) still gets its
      # colours, and the picker falls back to the generic "Game Light"/"Game Dark".
      names =
        case ThemePalette.names(anchors) do
          {:ok, names} -> names
          :error -> nil
        end

      {:ok, palette, names}
    end
  end

  defp build_palette(_), do: :skip

  defp name_summary(%{"light" => light, "dark" => dark}), do: "Named #{light} / #{dark}."
  defp name_summary(_), do: "Unnamed — using the default variant labels."

  @doc """
  Enqueue palette generation for a game that has a cover image. Expansions
  never get their own — they inherit the base game's palette (see
  `Games.effective_theme_palette/1`) — so this is a no-op for them regardless
  of caller.
  """
  def enqueue(%{id: id, image_url: url}) when is_binary(url) and url != "" do
    if Games.expansion?(id) do
      {:ok, :expansion_inherits}
    else
      %{game_id: id} |> new() |> Oban.insert()
    end
  end

  def enqueue(_), do: {:ok, :no_image}
end
