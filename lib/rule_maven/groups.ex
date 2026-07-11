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

  @rank %{"member" => 1, "admin" => 2, "owner" => 3}

  @doc "True if `user` currently belongs to `group`. Tolerates a nil user."
  def member?(user, group), do: role_of(user, group) != nil

  @doc """
  True if `user`'s role in `group` is at least `role` (member < admin < owner).
  `role` may be an atom or a string. Tolerates a nil user (always false).
  """
  def role_at_least?(user, group, role) do
    case role_of(user, group) do
      nil ->
        false

      current ->
        Map.fetch!(@rank, current) >= Map.fetch!(@rank, to_string(role))
    end
  end

  @doc "Lists the groups `user` belongs to, ordered by name. Empty list for a nil user."
  def list_for_user(nil), do: []

  def list_for_user(user) do
    Repo.all(
      from g in Group,
        join: m in Membership,
        on: m.group_id == g.id,
        where: m.user_id == ^user.id,
        order_by: [asc: g.name]
    )
  end

  @doc "Lists a group's members as plain maps with user_id, username, role."
  def list_members(%Group{id: group_id}) do
    Repo.all(
      from m in Membership,
        join: u in RuleMaven.Users.User,
        on: u.id == m.user_id,
        where: m.group_id == ^group_id,
        order_by: [asc: u.username],
        select: %{user_id: u.id, username: u.username, role: m.role}
    )
  end

  @doc """
  Renames the group. Requires the actor to be at least an admin.

  Returns `{:ok, group}`, `{:error, :forbidden}`, or `{:error, changeset}`
  for an invalid name.
  """
  def rename(actor, group, name) do
    if role_at_least?(actor, group, :admin) do
      group
      |> Group.changeset(%{name: name})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Rotates the group's invite code, immediately invalidating the old one
  (join_by_code looks up by exact code, so a stale code simply matches no
  group). Requires the actor to be at least an admin.
  """
  def regenerate_code(actor, group) do
    if role_at_least?(actor, group, :admin) do
      group
      |> Group.changeset(%{invite_code: generate_code()})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Promotes or demotes `target_user_id`'s role in the group. Owner-only —
  admins cannot change roles, including their own.

  Returns `{:error, :forbidden}` if the actor isn't the owner, or
  `{:error, :not_member}` if the target doesn't belong to the group.
  """
  def set_role(actor, group, target_user_id, role) do
    role = to_string(role)

    cond do
      not role_at_least?(actor, group, :owner) ->
        {:error, :forbidden}

      role not in Membership.roles() ->
        {:error, :forbidden}

      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil -> {:error, :not_member}
          membership -> membership |> Membership.changeset(%{role: role}) |> Repo.update()
        end
    end
  end

  @doc """
  Removes `target_user_id` from the group. Requires the actor to be at
  least an admin. The owner can never be removed by anyone — the DB's
  partial unique index guarantees exactly one owner per group, and
  transferring ownership is the only sanctioned way to change that.

  Returns `{:ok, :removed}`, `{:error, :forbidden}`,
  `{:error, :cannot_remove_owner}`, or `{:error, :not_member}`.
  """
  def remove_member(actor, group, target_user_id) do
    cond do
      not role_at_least?(actor, group, :admin) ->
        {:error, :forbidden}

      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil ->
            {:error, :not_member}

          %Membership{role: "owner"} ->
            {:error, :cannot_remove_owner}

          membership ->
            Repo.delete!(membership)
            {:ok, :removed}
        end
    end
  end

  @doc """
  Removes `user`'s own membership. The owner must transfer ownership
  (via `set_role/4`) before leaving, since a group must always have an
  owner.

  Returns `{:ok, :left}`, `{:error, :owner_must_transfer}`, or
  `{:error, :not_member}`.
  """
  def leave(user, group) do
    case Repo.get_by(Membership, group_id: group.id, user_id: user.id) do
      nil -> {:error, :not_member}
      %Membership{role: "owner"} -> {:error, :owner_must_transfer}
      membership ->
        Repo.delete!(membership)
        {:ok, :left}
    end
  end

  @doc """
  Deletes the group and (via FK cascade) its memberships. Owner-only.
  """
  def delete_group(actor, group) do
    if role_at_least?(actor, group, :owner) do
      Repo.delete!(group)
      {:ok, :deleted}
    else
      {:error, :forbidden}
    end
  end
end
