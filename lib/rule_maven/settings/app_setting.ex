defmodule RuleMaven.Settings.AppSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "app_settings" do
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> validate_length(:key, max: 200)
    |> validate_length(:value, max: 10_000)
    |> unique_constraint(:key)
  end
end
