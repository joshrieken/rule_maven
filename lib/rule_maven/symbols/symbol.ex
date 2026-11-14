defmodule RuleMaven.Symbols.Symbol do
  @moduledoc """
  One entry in a game's symbol key: an inline symbol token exactly as the
  transcription writes it (e.g. `"[purple hammer symbol]"`, or a numeric
  family like `"[black triangle: {n}]"`), what the book calls it, what it
  means, and an optional cropped icon image (served only through the gated
  `SymbolController`, never statically).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_symbols" do
    belongs_to :game, RuleMaven.Games.Game
    field :position, :integer, default: 0
    field :token, :string
    field :name, :string
    field :meaning, :string
    field :aliases, {:array, :string}, default: []
    field :page, :integer
    field :image_path, :string
    field :image_note, :string
    # "manual" (hand-authored import) or "llm" (SymbolKeyWorker).
    field :source, :string, default: "manual"

    timestamps(type: :utc_datetime)
  end

  def changeset(symbol, attrs) do
    symbol
    |> cast(
      attrs,
      ~w(game_id position token name meaning aliases page image_path image_note source)a
    )
    |> validate_required([:game_id, :token])
    |> validate_length(:token, max: 120)
    |> validate_length(:name, max: 120)
    |> validate_length(:meaning, max: 600)
    |> validate_inclusion(:source, ~w(manual llm))
    |> unique_constraint([:game_id, :token])
  end
end
