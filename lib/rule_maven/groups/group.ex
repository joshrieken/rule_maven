defmodule RuleMaven.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :name, :string
    field :invite_code, :string
    field :invite_active, :boolean, default: true
    field :member_cap, :integer, default: 12

    belongs_to :owner, RuleMaven.Users.User
    has_many :memberships, RuleMaven.Groups.Membership

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :owner_id, :invite_code, :invite_active, :member_cap])
    |> validate_required([:name, :owner_id, :invite_code])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint(:invite_code)
  end
end

defimpl Phoenix.Param, for: RuleMaven.Groups.Group do
  def to_param(%{id: id}), do: RuleMaven.Hashid.encode(id)
end
