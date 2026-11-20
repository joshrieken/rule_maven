defmodule RuleMaven.Games.Category do
  @moduledoc """
  The fixed list of game categories (value/label pairs) and which game
  metadata (BGG lookup, player counts) makes sense for each.
  """

  @categories [
    {"board_game", "Board Game"},
    {"card_game", "Card Game"},
    {"tabletop_rpg", "Tabletop RPG"},
    {"tcg", "Trading Card Game"},
    {"video_game", "Video Game"},
    {"other", "Other"}
  ]

  def all, do: @categories
  def options, do: Enum.map(@categories, fn {v, l} -> {l, v} end)

  def label(nil), do: "Board Game"
  def label(cat), do: Enum.find_value(@categories, cat, fn {v, l} -> if v == cat, do: l end)

  # BGG is relevant for board games and card games
  def bgg_relevant?(nil), do: true
  def bgg_relevant?("board_game"), do: true
  def bgg_relevant?("card_game"), do: true
  def bgg_relevant?("tcg"), do: true
  def bgg_relevant?(_), do: false

  # Whether player count metadata makes sense
  def player_count_relevant?(nil), do: true
  def player_count_relevant?("board_game"), do: true
  def player_count_relevant?("card_game"), do: true
  def player_count_relevant?("tcg"), do: true
  def player_count_relevant?("tabletop_rpg"), do: true
  def player_count_relevant?(_), do: false

  # Context noun for LLM prompt — "board game", "card game", etc.
  def context_noun(nil), do: "game"
  def context_noun("board_game"), do: "board game"
  def context_noun("card_game"), do: "card game"
  def context_noun("tabletop_rpg"), do: "tabletop RPG"
  def context_noun("tcg"), do: "trading card game"
  def context_noun("video_game"), do: "video game"
  def context_noun(_), do: "game"
end
