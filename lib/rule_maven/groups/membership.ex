defmodule RuleMaven.Groups.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member)

  schema "group_memberships" do
    field :role, :string, default: "member"
    belongs_to :user, RuleMaven.Users.User
    belongs_to :group, RuleMaven.Groups.Group
    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :group_id, :role])
    |> validate_required([:user_id, :group_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :group_id])
    |> unique_constraint(:group_id, name: :group_memberships_one_owner_index)
  end

  def roles, do: @roles
end
