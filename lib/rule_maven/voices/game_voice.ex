defmodule RuleMaven.Voices.GameVoice do
  @moduledoc """
  A per-game persona voice, generated from the game's own rulebook/theme so the
  voice list feels native to the game (a pirate game gets a salty quartermaster;
  a space 4X gets an imperial protocol droid).

  Like a built-in global voice it carries only `{label, emoji, style}` — the
  style is a tone instruction handed to the restyler, never a rule source. The
  `slug` is unique per game; the resolver exposes it to the rest of the app as
  the namespaced id `g:<slug>` so it can never shadow a global voice id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_voices" do
    field :slug, :string
    field :label, :string
    field :emoji, :string
    field :style, :string
    # Short user-facing blurb ("who is this persona?") shown in the voice menu.
    field :description, :string
    field :loading_phrases, {:array, :string}, default: []
    # In-character upvote thank-you toasts ("vote_thanks"); generic pool when empty.
    field :thanks_phrases, {:array, :string}, default: []
    # LLM-judged rank among this game's fans; 1 = most popular. Drives default
    # sort order in the voice picker (see Voices.game_voice_defs/1).
    field :popularity_rank, :integer
    # "generated" (rulebook-derived) — leaves room for hand-authored later.
    field :source, :string, default: "generated"
    field :position, :integer, default: 0
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime)
  end

  def changeset(gv, attrs) do
    gv
    |> cast(attrs, [
      :game_id,
      :slug,
      :label,
      :emoji,
      :style,
      :description,
      :loading_phrases,
      :thanks_phrases,
      :popularity_rank,
      :source,
      :position
    ])
    |> validate_required([:game_id, :slug, :label, :emoji, :style])
    |> unique_constraint([:game_id, :slug])
  end
end
