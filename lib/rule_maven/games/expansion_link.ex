defmodule RuleMaven.Games.ExpansionLink do
  @moduledoc """
  Join row linking an expansion game to ONE base game it works with. An
  expansion supported by several editions has one row per base (replaces the
  old single `games.parent_game_id` FK).
  """
  use Ecto.Schema

  schema "game_expansion_links" do
    belongs_to :expansion, RuleMaven.Games.Game, foreign_key: :expansion_id
    belongs_to :base_game, RuleMaven.Games.Game, foreign_key: :base_game_id
    timestamps(type: :utc_datetime)
  end
end
