defmodule RuleMaven.Games.HouseRule do
  @moduledoc """
  A user-authored house-rule variant for a game, with an LLM classification of
  how it relates to rules-as-written (verdict + verbatim RAW quote + note).
  Private by default; can be shared to the game's community list.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(matches fills_gap overrides unclear)
  @statuses ~w(pending done failed stale)

  schema "house_rules" do
    field :title, :string
    field :body, :string
    field :visibility, :string, default: "private"
    field :check_status, :string, default: "pending"
    field :verdict, :string
    field :raw_quote, :string
    field :check_note, :string
    field :citations, {:array, :map}
    field :checked_at, :utc_datetime
    field :blocked, :boolean, default: false
    field :body_embedding, Pgvector.Ecto.Vector

    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps()
  end

  def verdicts, do: @verdicts

  def changeset(hr, attrs) do
    hr
    |> cast(attrs, [:title, :body, :visibility])
    |> validate_required([:body])
    |> validate_length(:title, max: 80)
    |> validate_length(:body, max: 500)
    |> validate_inclusion(:visibility, ~w(private community))
  end

  def check_changeset(hr, attrs) do
    hr
    |> cast(attrs, [
      :check_status,
      :verdict,
      :raw_quote,
      :check_note,
      :citations,
      :checked_at,
      :body_embedding
    ])
    |> validate_inclusion(:check_status, @statuses)
    |> validate_inclusion(:verdict, @verdicts)
  end
end
