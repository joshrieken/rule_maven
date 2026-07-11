defmodule RuleMaven.Groups do
  @moduledoc """
  Persistent groups: a crew that shares a per-game feed and a private answer
  cache.
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Groups.{Group, Membership}

  @doc "Generate an opaque invite code."
  def generate_code, do: :crypto.strong_rand_bytes(8) |> Base.encode32(padding: false)

  @doc """
  Inserts a group and its owner membership row in one transaction. Rolls back
  the whole transaction (no orphan membership) if the group insert fails.
  """
  def create_group(owner, attrs) do
    code = generate_code()

    result =
      Repo.transaction(fn ->
        group_changeset =
          %Group{}
          |> Group.changeset(Map.merge(attrs, %{owner_id: owner.id, invite_code: code}))

        case Repo.insert(group_changeset) do
          {:ok, group} ->
            %Membership{}
            |> Membership.changeset(%{user_id: owner.id, group_id: group.id, role: "owner"})
            |> Repo.insert!()

            group

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, group} -> {:ok, group}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Looks up a group by its opaque hashid token. Returns nil for a garbage token."
  def get_group_by_token(token) do
    case RuleMaven.Hashid.decode(token) do
      {:ok, id} -> Repo.get(Group, id)
      :error -> nil
    end
  end

  @doc "Like `get_group_by_token/1` but raises `Ecto.NoResultsError` when absent."
  def get_group_by_token!(token) do
    case get_group_by_token(token) do
      nil -> raise Ecto.NoResultsError, queryable: Group
      group -> group
    end
  end

  @doc "Returns the user's role in the group, or nil if not a member. Tolerates a nil user."
  def role_of(nil, _group), do: nil

  def role_of(user, %Group{id: group_id}) do
    Repo.one(
      from m in Membership,
        where: m.user_id == ^user.id and m.group_id == ^group_id,
        select: m.role
    )
  end
end
