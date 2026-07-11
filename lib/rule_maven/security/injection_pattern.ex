defmodule RuleMaven.Security.InjectionPattern do
  use Ecto.Schema
  import Ecto.Changeset

  schema "injection_patterns" do
    field :pattern, :string
    field :category, :string
    field :enabled, :boolean, default: true
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, [:pattern, :category, :enabled, :note])
    |> validate_required([:pattern, :category])
    |> validate_length(:pattern, max: 500)
    |> validate_length(:category, max: 100)
    |> validate_length(:note, max: 1000)
    |> unique_constraint(:pattern)
    |> update_change(:pattern, &String.downcase(String.trim(&1)))
  end
end
