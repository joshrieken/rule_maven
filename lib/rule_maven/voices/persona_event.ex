defmodule RuleMaven.Voices.PersonaEvent do
  @moduledoc "One persona (voice) selection, used for popularity + recently-used."
  use Ecto.Schema
  import Ecto.Changeset

  schema "persona_events" do
    field :user_id, :id
    field :game_id, :id
    field :voice_id, :string
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :game_id, :voice_id])
    |> validate_required([:game_id, :voice_id])
  end
end
