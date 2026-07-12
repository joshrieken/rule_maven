defmodule RuleMavenWeb.GroupLive.Show do
  @moduledoc """
  Group settings: invite link + regenerate/toggle, member list with role
  management, rename, delete, leave.

  IDOR guard (per the no-ids-in-urls / server-authz project rule): mount
  resolves the group from its opaque Hashid token and immediately verifies
  `Groups.member?/2` before assigning anything — a non-member is
  `push_navigate`d away with a flash and never sees the group's name, invite
  code, or member list, even in the initial render. Every `handle_event`
  below re-derives the actor's authority from the DB via the `Groups`
  context (never trusts hidden/disabled state in the client) so a stale or
  tampered socket can't perform an action its owner no longer has.
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.Groups

  def mount(%{"token" => token}, _session, socket) do
    user = socket.assigns.current_user
    group = Groups.get_group_by_token(token)

    if is_nil(group) or not Groups.member?(user, group) do
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to that group.")
       |> push_navigate(to: ~p"/groups")}
    else
      {:ok, socket |> assign(page_title: group.name, group: group) |> load_group()}
    end
  end

  # Also the post-mutation RE-AUTHORIZATION point. An event can end the actor's
  # own membership (an admin removing themselves, or someone else removing them
  # while this page is open), and a stale page must not keep rendering a group
  # the viewer no longer belongs to — `role` would come back nil and the template
  # would crash on it. Membership is re-derived on every reload; losing it
  # redirects instead of assigning nil.
  defp load_group(socket) do
    user = socket.assigns.current_user
    group = Groups.get_group_by_token(Phoenix.Param.to_param(socket.assigns.group))

    case group && Groups.role_of(user, group) do
      nil ->
        socket
        |> put_flash(:info, "You're no longer a member of that group.")
        |> push_navigate(to: ~p"/groups")

      role ->
        socket
        |> assign(
          group: group,
          members: Groups.list_members(group),
          role: role,
          rename_form: to_form(%{"name" => group.name}, as: :group)
        )
    end
  end

  # --- Rename (admin+) --------------------------------------------------

  def handle_event("rename", %{"group" => %{"name" => name}}, socket) do
    case Groups.rename(socket.assigns.current_user, socket.assigns.group, name) do
      {:ok, _group} ->
        {:noreply, socket |> put_flash(:info, "Group renamed.") |> load_group()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to rename this group.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rename_form: to_form(changeset, as: :group))}
    end
  end

  # --- Invite link (admin+ to regenerate/toggle) -------------------------

  def handle_event("regenerate_code", _params, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    case Groups.regenerate_code(actor, group) do
      {:ok, _group} ->
        {:noreply, socket |> put_flash(:info, "Invite link regenerated.") |> load_group()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to regenerate the invite link.")}
    end
  end

  def handle_event("toggle_invite", _params, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    if Groups.role_at_least?(actor, group, :admin) do
      case Groups.set_invite_active(actor, group, !group.invite_active) do
        {:ok, _group} ->
          {:noreply, load_group(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Couldn't change the invite link.")}
      end
    else
      {:noreply,
       put_flash(socket, :error, "You don't have permission to change the invite link.")}
    end
  end

  # --- Community contribution (admin+) ------------------------------------

  def handle_event("toggle_contribute", _params, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    case Groups.set_contribute(actor, group, !group.contribute_to_community) do
      {:ok, _group} ->
        {:noreply, load_group(socket)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You don't have permission to change the community contribution setting."
         )}

      # set_contribute/3 runs in a transaction and can roll back with a changeset;
      # matching only {:ok, _} and :forbidden killed the LiveView with a
      # CaseClauseError.
      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't change the community contribution setting.")}
    end
  end

  # --- Roles (owner only) -------------------------------------------------

  def handle_event("set_role", %{"user_id" => user_id, "role" => role}, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _membership} <- Groups.set_role(actor, group, id, role) do
      {:noreply, load_group(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("transfer_ownership", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _group} <- Groups.transfer_ownership(actor, group, id) do
      {:noreply, socket |> put_flash(:info, "Ownership transferred.") |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # --- Membership ---------------------------------------------------------

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, :removed} <- Groups.remove_member(actor, group, id) do
      {:noreply,
       socket
       |> put_flash(:info, "Member removed. The invite link has been reset — share the new one.")
       |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("leave", _params, socket) do
    user = socket.assigns.current_user
    group = socket.assigns.group

    case Groups.leave(user, group) do
      {:ok, :left} ->
        {:noreply,
         socket
         |> put_flash(:info, "You left #{group.name}.")
         |> push_navigate(to: ~p"/groups")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("delete_group", _params, socket) do
    actor = socket.assigns.current_user
    group = socket.assigns.group

    case Groups.delete_group(actor, group) do
      {:ok, :deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{group.name} was deleted.")
         |> push_navigate(to: ~p"/groups")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # `phx-value-user_id` is client-controlled: a socket can push any string.
  # `String.to_integer/1` raises on garbage, taking the LiveView down and
  # putting the client into a reconnect loop.
  defp parse_user_id(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_member}
    end
  end

  defp parse_user_id(_), do: {:error, :not_member}

  defp error_message(:forbidden), do: "You don't have permission to do that."
  defp error_message(:cannot_remove_owner), do: "The group's owner can't be removed."
  defp error_message(:owner_must_transfer), do: "Transfer ownership before you leave."
  defp error_message(:last_owner), do: "The group's owner can't be demoted directly."

  defp error_message(:use_transfer_ownership),
    do: "Use \"Make owner\" to transfer ownership instead."

  defp error_message(:full), do: "This group is full."
  defp error_message(:inactive), do: "This group's invite link is off."
  defp error_message(:invalid_code), do: "That invite code isn't valid."
  defp error_message(:not_member), do: "That person isn't a member of this group."
  defp error_message(:use_leave), do: "Use \"Leave group\" to remove yourself."
  defp error_message(other), do: "Something went wrong (#{other})."

  defp invite_url(group), do: RuleMavenWeb.public_url(~p"/groups/join/#{group.invite_code}")

  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1rem">
      <.link navigate={~p"/groups"} class="back-link">&larr; Groups</.link>
      <h1 style="font-size:1.25rem;font-weight:800;margin:0 0 0.25rem 0">{@group.name}</h1>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem 0">
        Your role: <strong>{String.capitalize(@role)}</strong>
      </p>

      <!-- Invite link -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Invite link</h2>
        <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 0.6rem 0">
          Anyone with this link can join {@group.name}.
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
            class="btn-sm"
            style="white-space:nowrap"
            onclick={"navigator.clipboard.writeText('#{invite_url(@group)}').then(() => { this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Copy', 1500) })"}
          >
            Copy
          </button>
          <button
            :if={@role in ["admin", "owner"]}
            type="button"
            phx-click="regenerate_code"
            data-confirm="Regenerate the invite link? The old link will stop working."
            class="btn-sm"
            style="white-space:nowrap"
          >
            Regenerate
          </button>
          <button
            :if={@role in ["admin", "owner"]}
            type="button"
            phx-click="toggle_invite"
            class="btn-sm"
            style="white-space:nowrap"
          >
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
              <span style={role_badge_style(m.role)}>{String.capitalize(m.role)}</span>
              <span
                :if={m.user_id == @current_user.id}
                style="font-size:0.72rem;color:var(--text-muted)"
              >
                (you)
              </span>
            </div>
            <div style="display:flex;gap:0.4rem;flex-wrap:wrap">
              <button
                :if={@role == "owner" and m.role == "member" and m.user_id != @current_user.id}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="admin"
                class="btn-xs"
              >
                Make admin
              </button>
              <button
                :if={@role == "owner" and m.role == "admin" and m.user_id != @current_user.id}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="member"
                class="btn-xs"
              >
                Remove admin
              </button>
              <button
                :if={@role == "owner" and m.role != "owner" and m.user_id != @current_user.id}
                type="button"
                phx-click="transfer_ownership"
                phx-value-user_id={m.user_id}
                data-confirm={"Make #{m.username} the owner? You'll become an admin."}
                class="btn-xs"
              >
                Make owner
              </button>
              <button
                :if={
                  @role in ["admin", "owner"] and m.role != "owner" and
                    m.user_id != @current_user.id
                }
                type="button"
                phx-click="remove_member"
                phx-value-user_id={m.user_id}
                data-confirm={"Remove #{m.username} from #{@group.name}?\n\nThis also resets the invite link — otherwise they could just use it again. You'll need to re-share the new link with everyone else."}
                class="btn-danger-outline btn-xs"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>
      </section>

      <!-- Community contribution (admin+) -->
      <section
        :if={@role in ["admin", "owner"]}
        style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem"
      >
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Community sharing</h2>
        <label for="contribute-toggle" class="crew-toggle">
          <input
            type="checkbox"
            id="contribute-toggle"
            phx-click="toggle_contribute"
            checked={@group.contribute_to_community}
          />
          <span class="crew-toggle__text">
            <span class="crew-toggle__label">Contribute answers to the community</span>
            <span class="crew-toggle__hint">
              On: your crew's answers feed the community's shared cache, and your questions
              can be listed publicly — but only reworded to remove names and personal
              details, and only after an automatic privacy check clears them. Off: neither
              happens. Turning it off also withdraws what you've already shared (unless the
              community voted it in), permanently — turning it back on shares future
              answers only.
            </span>
          </span>
        </label>
      </section>

      <!-- Rename (admin+) -->
      <section
        :if={@role in ["admin", "owner"]}
        style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem"
      >
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Rename group</h2>
        <.form
          for={@rename_form}
          id="rename-group"
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
        <div style="display:flex;gap:0.5rem;flex-wrap:wrap">
          <button
            :if={@role != "owner"}
            type="button"
            phx-click="leave"
            data-confirm={"Leave #{@group.name}?"}
            class="btn-danger-outline btn-sm"
          >
            Leave group
          </button>
          <button
            :if={@role == "owner"}
            type="button"
            phx-click="delete_group"
            data-confirm={"Delete #{@group.name}? This can't be undone."}
            class="btn-danger btn-sm"
          >
            Delete group
          </button>
        </div>
      </section>
    </div>
    """
  end

  defp role_badge_style("owner"),
    do:
      "font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.5rem;background:color-mix(in srgb,var(--accent) 18%,transparent);color:var(--accent)"

  defp role_badge_style("admin"),
    do:
      "font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.5rem;background:var(--bg-subtle);color:var(--text)"

  defp role_badge_style(_),
    do:
      "font-size:0.7rem;font-weight:600;border-radius:999px;padding:0.1rem 0.5rem;background:var(--bg-subtle);color:var(--text-muted)"
end
