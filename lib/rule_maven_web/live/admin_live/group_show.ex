defmodule RuleMavenWeb.AdminLive.GroupShow do
  @moduledoc """
  Per-group admin detail page. Every control here calls the `admin_*`
  functions on `RuleMaven.Groups` — no membership or in-group role is
  required of the acting admin, unlike `RuleMavenWeb.GroupLive.Show` (the
  member-facing settings page this UI is adapted from). Every mutation is
  audit-logged (`target_type: "group"`).
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Groups, Users}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      case Groups.get_group_by_token(token) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "That group doesn't exist.")
           |> push_navigate(to: ~p"/admin/groups")}

        group ->
          {:ok, socket |> assign(page_title: group.name, group: group) |> load_group()}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load_group(socket) do
    group = Groups.get_group_by_token(Phoenix.Param.to_param(socket.assigns.group))
    owner_membership = Enum.find(Groups.list_members(group), &(&1.role == "owner"))

    assign(socket,
      group: group,
      members: Groups.list_members(group),
      owner_username: owner_membership && owner_membership.username,
      viewer_role: Groups.role_of(socket.assigns.current_user, group),
      rename_form: to_form(%{"name" => group.name}, as: :group)
    )
  end

  # --- Rename --------------------------------------------------------------

  @impl true
  def handle_event("rename", %{"group" => %{"name" => name}}, socket) do
    group = socket.assigns.group

    case Groups.admin_rename(group, name) do
      {:ok, _group} ->
        audit(socket, "group.rename", group, %{name: name})
        {:noreply, socket |> put_flash(:info, "Group renamed.") |> load_group()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rename_form: to_form(changeset, as: :group))}
    end
  end

  # --- Invite link -----------------------------------------------------------

  @impl true
  def handle_event("regenerate_code", _params, socket) do
    group = socket.assigns.group
    Groups.admin_regenerate_code(group)
    audit(socket, "group.regenerate_code", group, %{})
    {:noreply, socket |> put_flash(:info, "Invite link regenerated.") |> load_group()}
  end

  @impl true
  def handle_event("toggle_invite", _params, socket) do
    group = socket.assigns.group
    active? = !group.invite_active

    case Groups.admin_set_invite_active(group, active?) do
      {:ok, _group} ->
        audit(socket, "group.toggle_invite", group, %{active: active?})
        {:noreply, load_group(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the invite link.")}
    end
  end

  # --- Community contribution -------------------------------------------------

  @impl true
  def handle_event("toggle_contribute", _params, socket) do
    group = socket.assigns.group
    contribute? = !group.contribute_to_community

    case Groups.admin_set_contribute(group, contribute?) do
      {:ok, _group} ->
        audit(socket, "group.set_contribute", group, %{contribute: contribute?})
        {:noreply, load_group(socket)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't change the community contribution setting."
         )}
    end
  end

  # --- Member cap --------------------------------------------------------

  @impl true
  def handle_event("set_member_cap", %{"member_cap" => cap_str}, socket) do
    group = socket.assigns.group

    with {cap, ""} <- Integer.parse(cap_str),
         {:ok, _group} <- Groups.admin_set_member_cap(group, cap) do
      audit(socket, "group.set_member_cap", group, %{cap: cap})
      {:noreply, socket |> put_flash(:info, "Member cap updated.") |> load_group()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Enter a whole number greater than zero.")}
    end
  end

  # --- Roles ---------------------------------------------------------------

  @impl true
  def handle_event("set_role", %{"user_id" => user_id, "role" => role}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _membership} <- Groups.admin_set_role(group, id, role) do
      audit(socket, "group.set_role", group, %{user_id: id, role: role})
      {:noreply, load_group(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_event("transfer_ownership", %{"user_id" => user_id}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _group} <- Groups.admin_transfer_ownership(group, id) do
      audit(socket, "group.transfer_ownership", group, %{new_owner_id: id})
      {:noreply, socket |> put_flash(:info, "Ownership transferred.") |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # --- Membership ------------------------------------------------------------

  @impl true
  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, :removed} <- Groups.admin_remove_member(group, id) do
      audit(socket, "group.remove_member", group, %{user_id: id})

      {:noreply,
       socket
       |> put_flash(:info, "Member removed. The invite link has been reset.")
       |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_event("delete_group", _params, socket) do
    group = socket.assigns.group

    case Groups.admin_delete_group(group) do
      {:ok, :deleted} ->
        audit(socket, "group.delete", group, %{})

        {:noreply,
         socket
         |> put_flash(:info, "#{group.name} was deleted.")
         |> push_navigate(to: ~p"/admin/groups")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete #{group.name}.")}
    end
  end

  defp audit(socket, action, group, metadata) do
    Audit.log(socket.assigns.current_user, action,
      target_type: "group",
      target_id: group.id,
      target_label: group.name,
      metadata: metadata
    )
  end

  defp parse_user_id(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_member}
    end
  end

  defp parse_user_id(_), do: {:error, :not_member}

  defp error_message(:not_member), do: "That person isn't a member of this group."
  defp error_message(:last_owner), do: "The group's owner can't be demoted directly."
  defp error_message(:cannot_remove_owner), do: "The group's owner can't be removed."
  defp error_message(:invalid_role), do: "That isn't a valid role."

  defp error_message(:use_transfer_ownership),
    do: "Use \"Make owner\" to transfer ownership instead."

  defp error_message(other), do: "Something went wrong (#{other})."

  defp invite_url(group), do: url(~p"/groups/join/#{group.invite_code}")

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1rem">
      <.link navigate={~p"/admin/groups"} class="back-link">&larr; All groups</.link>

      <div style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;flex-wrap:wrap;margin:0.5rem 0 0.25rem">
        <h1 style="font-size:1.25rem;font-weight:800;margin:0">{@group.name}</h1>
      </div>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 0.5rem 0">
        Owner: <strong>{@owner_username}</strong>
      </p>

      <div
        :if={is_nil(@viewer_role)}
        style="padding:0.5rem 0.75rem;margin-bottom:1.25rem;border-radius:0.5rem;border:1px solid var(--accent);background:var(--bg-surface);font-size:0.78rem;color:var(--text)"
      >
        Admin view — you are not a member of this group. Every control below acts
        on the group directly.
      </div>

      <!-- Invite link -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Invite link</h2>
        <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 0.6rem 0">
          <%= if @group.invite_active do %>
            Currently <strong style="color:var(--green)">active</strong>.
          <% else %>
            Currently <strong style="color:var(--text-muted)">off</strong> — new joins are blocked.
          <% end %>
        </p>
        <div style="display:flex;gap:0.5rem;flex-wrap:wrap;align-items:center">
          <input
            type="text"
            readonly
            value={invite_url(@group)}
            id="invite-url"
            onclick="this.select()"
            style="flex:1;min-width:12rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.8rem"
          />
          <button
            type="button"
            phx-click="regenerate_code"
            data-confirm="Regenerate the invite link? The old link will stop working."
            class="btn-sm"
          >
            Regenerate
          </button>
          <button type="button" phx-click="toggle_invite" class="btn-sm">
            {if @group.invite_active, do: "Turn off invite", else: "Turn on invite"}
          </button>
        </div>
      </section>

      <!-- Members -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">
          Members ({length(@members)})
        </h2>
        <ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:0.5rem">
          <li
            :for={m <- @members}
            style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;flex-wrap:wrap;padding:0.5rem 0;border-bottom:1px solid var(--border-subtle,var(--border))"
          >
            <div style="display:flex;align-items:center;gap:0.5rem;min-width:0">
              <span style="font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                {m.username}
              </span>
              <span style="font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.5rem;background:var(--bg-subtle);color:var(--text)">
                {String.capitalize(m.role)}
              </span>
            </div>
            <div style="display:flex;gap:0.4rem;flex-wrap:wrap">
              <button
                :if={m.role == "member"}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="admin"
                class="btn-xs"
              >
                Make admin
              </button>
              <button
                :if={m.role == "admin"}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="member"
                class="btn-xs"
              >
                Remove admin
              </button>
              <button
                :if={m.role != "owner"}
                type="button"
                phx-click="transfer_ownership"
                phx-value-user_id={m.user_id}
                data-confirm={"Make #{m.username} the owner?"}
                class="btn-xs"
              >
                Make owner
              </button>
              <button
                :if={m.role != "owner"}
                type="button"
                phx-click="remove_member"
                phx-value-user_id={m.user_id}
                data-confirm={"Remove #{m.username} from #{@group.name}?\n\nThis also resets the invite link."}
                class="btn-danger-outline btn-xs"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>
      </section>

      <!-- Member cap -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Member cap</h2>
        <form
          id="admin-set-cap"
          phx-submit="set_member_cap"
          style="display:flex;gap:0.5rem;flex-wrap:wrap"
        >
          <input
            type="number"
            name="member_cap"
            value={@group.member_cap}
            min="1"
            style="width:6rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.85rem"
          />
          <button type="submit" class="btn-sm">Save</button>
        </form>
      </section>

      <!-- Community contribution -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Community sharing</h2>
        <label for="admin-contribute-toggle" class="crew-toggle">
          <input
            type="checkbox"
            id="admin-contribute-toggle"
            phx-click="toggle_contribute"
            checked={@group.contribute_to_community}
          />
          <span class="crew-toggle__text">
            <span class="crew-toggle__label">Contribute answers to the community</span>
          </span>
        </label>
      </section>

      <!-- Rename -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Rename group</h2>
        <.form
          for={@rename_form}
          id="admin-rename-group"
          phx-submit="rename"
          style="display:flex;gap:0.5rem;flex-wrap:wrap"
        >
          <input
            type="text"
            name="group[name]"
            value={@rename_form[:name].value}
            maxlength="60"
            required
            style="flex:1;min-width:12rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.85rem"
          />
          <button type="submit" class="btn-sm">Rename</button>
        </.form>
      </section>

      <!-- Danger zone -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface)">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Danger zone</h2>
        <button
          type="button"
          phx-click="delete_group"
          data-confirm={"Delete #{@group.name}? This can't be undone."}
          class="btn-danger btn-sm"
        >
          Delete group
        </button>
      </section>
    </div>
    """
  end
end
