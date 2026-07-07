defmodule RuleMaven.RuleOfTheDay do
  @moduledoc """
  Daily obscure-rule spotlight for the homepage: one generated "did you know"
  fact from one Ready game, rotating deterministically with the UTC date so
  every visitor (and both the static and connected mounts) sees the same pick
  all day.

  Pure read — draws from the DidYouKnow facts already cached in Settings and
  never triggers generation.
  """

  import Ecto.Query

  alias RuleMaven.{Repo, Settings}
  alias RuleMaven.Games.Game

  @doc """
  The spotlight for `date` as `%{game: %Game{}, fact: text}`, or nil when no
  Ready game has generated facts yet.
  """
  def pick(date \\ Date.utc_today()) do
    entries =
      Settings.all()
      |> Enum.flat_map(&fact_entry/1)
      |> Map.new()

    playable =
      case Map.keys(entries) do
        [] ->
          []

        ids ->
          Repo.all(
            from g in Game,
              where: g.id in ^ids and g.playable == true and is_nil(g.taken_down_at),
              order_by: g.id
          )
      end

    case playable do
      [] ->
        nil

      games ->
        day = Date.to_erl(date)
        game = Enum.at(games, :erlang.phash2(day, length(games)))
        facts = Map.fetch!(entries, game.id)
        %{game: game, fact: clean(Enum.at(facts, :erlang.phash2({day, game.id}, length(facts))))}
    end
  end

  defp fact_entry({"did_you_know_" <> id, json}) do
    with {game_id, ""} <- Integer.parse(id),
         {:ok, facts} when is_list(facts) and facts != [] <- Jason.decode(json) do
      [{game_id, facts}]
    else
      _ -> []
    end
  end

  defp fact_entry(_), do: []

  # Facts are generated without page markers, but strip defensively so a stray
  # "[Page N]" never reaches the homepage card.
  defp clean(text) do
    text
    |> to_string()
    |> String.replace(~r/\[Page\s*\d+\]/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
