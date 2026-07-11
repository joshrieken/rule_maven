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

  @doc "Counts current members of the group."
  def member_count(%Group{id: group_id}) do
    Repo.aggregate(from(m in Membership, where: m.group_id == ^group_id), :count)
  end

  @doc "Flips whether the group's invite code currently accepts new joins."
  def set_invite_active(%Group{} = group, active?) when is_boolean(active?) do
    group
    |> Group.changeset(%{invite_active: active?})
    |> Repo.update()
  end

  @doc "Sets the maximum number of members the group may hold."
  def set_member_cap(%Group{} = group, cap) when is_integer(cap) do
    group
    |> Group.changeset(%{member_cap: cap})
    |> Repo.update()
  end

  @doc """
  Joins `user` to the group identified by `code`.

  The cap check and membership insert happen inside a Postgres transaction
  that first takes a transaction-scoped advisory lock keyed on the group id
  (`pg_advisory_xact_lock`). That serializes concurrent joiners for the same
  group: only one joining transaction can be inside the count-then-insert
  section for a given group at a time, so the count read is never stale by
  the time we decide whether to insert. Ordinary READ COMMITTED semantics
  are NOT sufficient here on their own (two concurrent transactions can each
  fail to see the other's uncommitted insert and both pass the cap check);
  the advisory lock closes that race. The lock releases automatically when
  the transaction ends. The `[:user_id, :group_id]` unique index remains as
  a backstop against duplicate membership rows.

  Returns:
    * `{:ok, membership}`
    * `{:error, :invalid_code}` - no group has this invite code
    * `{:error, :inactive}` - the group's invite link is turned off
    * `{:error, :already_member}` - the user already belongs to the group
    * `{:error, :full}` - the group is at or over its member cap
  """
  def join_by_code(user, code) do
    case Repo.get_by(Group, invite_code: code) do
      nil ->
        {:error, :invalid_code}

      %Group{invite_active: false} ->
        {:error, :inactive}

      %Group{} = group ->
        do_join(user, group)
    end
  end

  defp do_join(user, %Group{id: group_id, member_cap: cap}) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [group_id])

        cond do
          role_of(user, %Group{id: group_id}) ->
            Repo.rollback(:already_member)

          member_count(%Group{id: group_id}) >= cap ->
            Repo.rollback(:full)

          true ->
            %Membership{}
            |> Membership.changeset(%{user_id: user.id, group_id: group_id, role: "member"})
            |> Repo.insert!()
        end
      end)

    case result do
      {:ok, membership} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
  end
end
