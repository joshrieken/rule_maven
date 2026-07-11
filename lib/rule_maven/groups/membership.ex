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
  end

  def roles, do: @roles
end
