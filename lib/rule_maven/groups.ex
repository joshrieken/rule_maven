defmodule RuleMaven.Groups do
  @moduledoc """
  Persistent groups: a crew that shares a per-game feed and a private answer
  cache.
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Groups.{Group, Membership}

  # Advisory locks live in ONE flat 64-bit keyspace, so a single-argument
  # `pg_advisory_xact_lock(id)` keyed on a group id collides with the same call
  # keyed on a user id — group 7 and user 7 contend for the same lock. Use the
  # two-argument (class, id) form everywhere. Class 1 is the per-user quota
  # lock in `RuleMaven.Games`; class 2 is the per-group lock here.
  @group_lock_class 2

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

  @doc """
  Whether a group contributes its answers to the community cache. `true` for a
  nil group_id — a non-group ask always contributes, as it always has.

  A group_id that no longer resolves means the crew was DELETED while this ask
  was in flight (AskWorker's `group_id` can come from the Oban arg, which
  outlives the row's nilified column). That must fail CLOSED: defaulting to
  `true` there would pool the answer of a crew that had contribution switched
  off, seconds after `delete_group/2` explicitly retracted everything it had
  ever shared.
  """
  def contribute_to_community?(nil), do: true

  def contribute_to_community?(group_id) do
    case Repo.get(Group, group_id) do
      nil -> false
      group -> group.contribute_to_community
    end
  end

  @doc "Looks up a group by its opaque hashid token. Returns nil for a garbage token."
  def get_group_by_token(token) do
    case RuleMaven.Hashid.decode(token) do
      {:ok, id} -> Repo.get(Group, id)
      :error -> nil
    end
  end

  @doc """
  Looks up a group by its invite code, regardless of whether the code is
  currently active. Used by the join flow to show the group's name even
  when the invite has been turned off or capped, so the error screen can
  say *what* you were trying to join. Returns nil for an unknown code.
  """
  def get_group_by_code(code), do: Repo.get_by(Group, invite_code: code)

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

  @doc """
  Flips whether the group's invite code currently accepts new joins.
  Requires the actor to be at least an admin.

  Every other mutator in this module takes an actor and gates on
  `role_at_least?/3`; these two did not, and were safe only because the one
  caller happened to check the role at the call site. That is not a property the
  next caller inherits — a gate that lives in the LiveView is a gate the context
  does not have.
  """
  def set_invite_active(actor, %Group{} = group, active?) when is_boolean(active?) do
    if role_at_least?(actor, group, :admin) do
      group
      |> Group.changeset(%{invite_active: active?})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Sets the maximum number of members the group may hold. Admin or owner only.
  """
  def set_member_cap(actor, %Group{} = group, cap) when is_integer(cap) do
    if role_at_least?(actor, group, :admin) do
      group
      |> Group.changeset(%{member_cap: cap})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
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
  def join_by_code(user, code) when is_binary(code) do
    result =
      Repo.transaction(fn ->
        # The FIRST read only tells us which group to lock. Every credential
        # this join rests on — the code itself, the active flag, the cap — is
        # re-read INSIDE the lock, because all three can change while a joiner
        # is in flight. Reading them once, up front, made removal defeatable:
        # `remove_member/3` rotates the invite code precisely so a kicked
        # member can't reuse their link, but a join that had already passed
        # the outside-the-lock lookup sailed straight past the rotation and
        # re-inserted the membership row that had just been deleted.
        case Repo.get_by(Group, invite_code: code) do
          nil ->
            Repo.rollback(:invalid_code)

          %Group{id: group_id} ->
            Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group_id])
            do_join(user, group_id, code)
        end
      end)

    case result do
      {:ok, membership} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs holding the group's advisory lock. `code` is re-verified here: if it
  # no longer names this group, the key we were shown has been changed since.
  defp do_join(user, group_id, code) do
    case Repo.get(Group, group_id) do
      %Group{invite_code: ^code, invite_active: true, member_cap: cap} ->
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

      %Group{invite_code: ^code, invite_active: false} ->
        Repo.rollback(:inactive)

      # Rotated (or deleted) out from under us between the two reads. The code
      # we were handed is no longer a key to this door.
      _ ->
        Repo.rollback(:invalid_code)
    end
  end

  @rank %{"member" => 1, "admin" => 2, "owner" => 3}

  @doc "True if `user` currently belongs to `group`. Tolerates a nil user."
  def member?(user, group), do: role_of(user, group) != nil

  @doc """
  True if `user_id` currently belongs to the group identified by `group_id`,
  checked directly against the membership table (no struct fetch required).
  Tolerates a nil `user_id` or `group_id` (always false). Used to verify a
  caller-supplied `group_id` — e.g. one that arrived via an Oban job arg or
  LiveView assign — actually belongs to the acting user before it is trusted
  for anything privileged, since `group_id` alone is not proof of membership.
  """
  def member_of_group_id?(nil, _group_id), do: false
  def member_of_group_id?(_user_id, nil), do: false

  def member_of_group_id?(user_id, group_id) do
    Repo.exists?(from m in Membership, where: m.user_id == ^user_id and m.group_id == ^group_id)
  end

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
  Sets whether the group's answers contribute to the community cache
  (`contribute_to_community`). Requires the actor to be at least an admin —
  same authorization shape as `rename/3`, via `role_at_least?/3`. A caller
  without permission gets `{:error, :forbidden}`, like every other function in
  this module.

  When off, `AskWorker` forces `never_pool` for every ask made under this
  group (see `contribute_to_community?/1`); the group's questions stay
  private either way, this only affects whether the *answers* feed the
  shared community cache.
  """
  def set_contribute(actor, %Group{} = group, contribute?) when is_boolean(contribute?) do
    if role_at_least?(actor, group, :admin) do
      Repo.transaction(fn ->
        result =
          group
          |> Group.changeset(%{contribute_to_community: contribute?})
          |> Repo.update()

        case result do
          {:ok, updated} ->
            if not contribute?, do: retract_contributions(group)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  # Turning contribution off has to be retroactive, not just future-facing.
  # The setting was previously read only at ask time, so a crew that flipped it
  # off left every answer it had already contributed serving the cross-user
  # cache, and every question the publish check had already cleared listed on
  # the community browse — "stop sharing" that stopped nothing already shared.
  #
  # Rows already promoted to `visibility: "community"` are left alone: those
  # passed a community vote and belong to the commons, not to the crew.
  # `retracted_at` is the DURABLE record of the withdrawal. Clearing `pooled` and
  # `browsable` states what the row looks like NOW; it says nothing about intent,
  # and both flags are writable by the ask pipeline. An ask already in flight
  # re-pooled the row seconds later (`never_pool` is read once, ~180s earlier),
  # and toggling contribution back on made every previously-withdrawn row
  # eligible again — against a UI that calls the withdrawal permanent. AskWorker
  # and PublishCheckWorker both refuse a row carrying this stamp, so neither the
  # race nor the re-toggle can resurrect it.
  defp retract_contributions(%Group{id: group_id}) do
    from(q in RuleMaven.Games.QuestionLog,
      where: q.group_id == ^group_id,
      where: q.visibility != "community"
    )
    |> Repo.update_all(set: [pooled: false, browsable: false, retracted_at: DateTime.utc_now()])
  end

  @doc """
  Rotates the group's invite code, immediately invalidating the old one
  (join_by_code looks up by exact code, so a stale code simply matches no
  group). Requires the actor to be at least an admin.
  """
  def regenerate_code(actor, group) do
    if role_at_least?(actor, group, :admin) do
      # Same critical section as `join_by_code/2` and `remove_member/3`: a
      # rotation that doesn't hold the lock can be straddled by a join that
      # already read the old code, which then lands anyway.
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

        group
        |> Group.changeset(%{invite_code: generate_code()})
        |> Repo.update!()
      end)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Promotes or demotes `target_user_id`'s role in the group. Owner-only —
  admins cannot change roles, including their own.

  This function can never create or destroy an owner: it cannot touch a
  membership row that currently holds "owner" (use `transfer_ownership/3`
  to move ownership), and it cannot promote anyone to "owner" either.

  Returns `{:error, :forbidden}` if the actor isn't the owner,
  `{:error, :not_member}` if the target doesn't belong to the group,
  `{:error, :last_owner}` if the target currently holds "owner", or
  `{:error, :use_transfer_ownership}` if the requested role is "owner".
  """
  def set_role(actor, group, target_user_id, role) do
    role = to_string(role)

    cond do
      not role_at_least?(actor, group, :owner) ->
        {:error, :forbidden}

      role not in Membership.roles() ->
        {:error, :forbidden}

      role == "owner" ->
        {:error, :use_transfer_ownership}

      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil -> {:error, :not_member}
          %Membership{role: "owner"} -> {:error, :last_owner}
          membership -> membership |> Membership.changeset(%{role: role}) |> Repo.update()
        end
    end
  end

  @doc """
  Transfers ownership of `group` from the current owner to
  `new_owner_user_id`. This is the ONLY sanctioned way to move ownership —
  `set_role/4` refuses to touch an owner row in either direction.

  Runs inside a single transaction, first taking a transaction-scoped
  advisory lock keyed on the group id (same pattern as `join_by_code/2`),
  THEN re-verifies authorization: the actor must still hold "owner" on this
  group at the moment the lock is held. The naive approach — checking
  `role_at_least?(actor, group, :owner)` before opening the transaction —
  is a TOCTOU: two concurrent transfers by the same owner can both pass
  that outer check (neither has committed yet), and the loser, once it
  gets the lock, would otherwise blindly re-derive "whoever currently
  holds role: owner" and demote whoever the winner just promoted — a
  second, unconsented transfer away from the actual current owner. Pinning
  the check to the actor's own row under the lock closes that race:
  the loser sees that role: "owner" no longer belongs to `actor` and
  rolls back `:forbidden` instead of acting.

  Demotes the current owner to "admin" and promotes the target to
  "owner", in that order, so the DB's partial unique index
  (`group_memberships_one_owner_index`, one "owner" row per group) is
  never transiently violated.

  Returns `{:ok, group}`, `{:error, :forbidden}` if the actor isn't (or
  is no longer) the owner, or `{:error, :not_member}` if the target
  doesn't belong to the group.
  """
  def transfer_ownership(actor, group, new_owner_user_id) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

        current_owner = Repo.get_by(Membership, group_id: group.id, role: "owner")

        cond do
          is_nil(current_owner) or current_owner.user_id != actor.id ->
            Repo.rollback(:forbidden)

          true ->
            case Repo.get_by(Membership, group_id: group.id, user_id: new_owner_user_id) do
              nil ->
                Repo.rollback(:not_member)

              target_membership ->
                current_owner
                |> Membership.changeset(%{role: "admin"})
                |> Repo.update!()

                target_membership
                |> Membership.changeset(%{role: "owner"})
                |> Repo.update!()

                # `groups.owner_id` is a denormalized pointer that must
                # track whichever membership row holds role: "owner". Left
                # stale, it would keep referencing the OLD owner even
                # though they're now a mere admin — and since that column
                # is `null: false` while its FK is `on_delete: :nilify_all`,
                # deleting that former owner's account later would crash
                # on a not-null violation instead of leaving the group
                # (which they no longer own) untouched.
                group
                |> Group.changeset(%{owner_id: new_owner_user_id})
                |> Repo.update!()
            end
        end
      end)

    case result do
      {:ok, group} -> {:ok, group}
      {:error, reason} -> {:error, reason}
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

      # Removing yourself is `leave/2`, not `remove_member/3`. Without this an
      # admin could delete their OWN membership row here, after which the caller
      # holds a page for a group they are no longer in (role comes back nil).
      # Routing self-removal through leave/2 also keeps the owner-must-transfer
      # guard in one place.
      actor.id == target_user_id ->
        {:error, :use_leave}

      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil ->
            {:error, :not_member}

          %Membership{role: "owner"} ->
            {:error, :cannot_remove_owner}

          membership ->
            # Rotate the invite code in the same breath. The invite URL is shown
            # to EVERY member, not just admins, so a removed member is holding a
            # working key to the door they were just shown out of: `join_by_code/2`
            # checks only that the code exists and the link is active, and there is
            # no blocklist. Deleting the membership row alone bought nothing — they
            # re-open the link and they are back in, with full feed access and no
            # signal to the admin, as many times as they like.
            #
            # Rotating costs the crew a re-share of the link; not rotating makes
            # removal decorative.
            #
            # Under the SAME advisory lock `join_by_code/2` takes. A lock only
            # serializes the transactions that TAKE it: the joiner re-reads the
            # code inside the lock, but if the remover doesn't hold it, the two
            # still interleave — the joiner reads the group (code still valid),
            # the removal commits (row deleted, code rotated), and the joiner's
            # `role_of` then sees no membership and re-inserts the row that was
            # just deleted. Removal is only durable if the remover is inside the
            # same critical section the joiner is racing against.
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

              Repo.delete!(membership)

              group
              |> Group.changeset(%{invite_code: generate_code()})
              |> Repo.update!()
            end)

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
      nil ->
        {:error, :not_member}

      %Membership{role: "owner"} ->
        {:error, :owner_must_transfer}

      membership ->
        Repo.delete!(membership)
        {:ok, :left}
    end
  end

  @doc """
  Deletes the group and (via FK cascade) its memberships. Owner-only.

  Retracts the crew's contributions FIRST. `questions_log.group_id` is
  `on_delete: :nilify_all`, so deleting the group strips its rows of the only
  marker that says they came from a crew — while leaving the unscreened text in
  place. Anything that then asks "is this a crew row?" by looking at `group_id`
  gets the wrong answer, so the rows are closed here, while we can still find
  them, rather than left for a guard to misjudge later.
  """
  def delete_group(actor, group) do
    if role_at_least?(actor, group, :owner) do
      Repo.transaction(fn ->
        retract_contributions(group)
        Repo.delete!(group)
        :deleted
      end)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Must be called (and committed) BEFORE deleting a user's account, for
  every group that user owns. Without this, deleting the account leaves
  an unrecoverable state: `group_memberships.user_id` cascades on delete
  (the owner's membership row vanishes) but `groups.owner_id` only
  nilifies (the group survives) — the group ends up with zero "owner"
  rows, and every owner-gated operation (`transfer_ownership/3`,
  `set_role/4`, `delete_group/2`) requires one to exist.

  For each group the departing user owns, runs under the same
  transaction-scoped advisory lock used by `join_by_code/2` and
  `transfer_ownership/3`, then either:

    * promotes the most senior remaining member to "owner" — an existing
      "admin" is preferred; otherwise the oldest "member" by
      `inserted_at`; or
    * deletes the group outright if the departing owner was its only
      member (nothing left to preserve).

  Caller is expected to run this inside the same transaction as the
  user delete so there is never a window where the user row is gone but
  a group is still ownerless. Returns `:ok`.
  """
  def handle_owner_account_deletion(%RuleMaven.Users.User{id: user_id}) do
    owned_group_ids =
      Repo.all(
        from m in Membership,
          where: m.user_id == ^user_id and m.role == "owner",
          select: m.group_id
      )

    Enum.each(owned_group_ids, &fixup_owner_departure(&1, user_id))
    :ok
  end

  defp fixup_owner_departure(group_id, departing_owner_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group_id])

      candidates =
        Repo.all(
          from m in Membership,
            where: m.group_id == ^group_id and m.user_id != ^departing_owner_id,
            order_by: [
              asc: fragment("case when ? = 'admin' then 0 else 1 end", m.role),
              asc: m.inserted_at
            ]
        )

      case candidates do
        [] ->
          # Same retraction delete_group/2 does, and for the same reason: the
          # delete nilifies questions_log.group_id, so the rows must be closed
          # while they can still be found.
          retract_contributions(%Group{id: group_id})
          Repo.delete_all(from g in Group, where: g.id == ^group_id)

        [heir | _] ->
          # The departing owner's own membership row still holds role
          # "owner" at this point — the user row (and its cascade) hasn't
          # been deleted yet, since this fixup runs BEFORE that delete in
          # the same transaction. Promoting the heir straight to "owner"
          # while that row is still there would collide with the partial
          # unique index (one "owner" row per group). Clear it first; the
          # user row is about to be deleted anyway so this row would be
          # cascade-removed a moment later regardless.
          Repo.delete_all(
            from m in Membership,
              where: m.group_id == ^group_id and m.user_id == ^departing_owner_id
          )

          heir
          |> Membership.changeset(%{role: "owner"})
          |> Repo.update!()

          # Keep the denormalized `groups.owner_id` pointer in sync too —
          # see the matching note in `transfer_ownership/3`. Without this,
          # `groups.owner_id` still points at the departing user, and
          # `Repo.delete(user)` a moment later (same transaction) hits the
          # FK's `on_delete: :nilify_all` against a `null: false` column.
          Repo.get!(Group, group_id)
          |> Group.changeset(%{owner_id: heir.user_id})
          |> Repo.update!()
      end
    end)
  end
end
