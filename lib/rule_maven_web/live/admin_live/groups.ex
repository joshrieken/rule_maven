defmodule RuleMavenWeb.AdminLive.Groups do
  @moduledoc """
  Admin-wide group browser: every group in the system, searchable by name,
  with a link to the per-group admin detail page and a delete action. Any
  `Users.can?(user, :admin)` user gets full access — see
  `docs/superpowers/specs/2026-07-11-admin-group-management-design.md` for
  why this isn't split off to super-admin-only.
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Groups, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Manage Groups", search: "", rows: Groups.list_all())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search, rows: Groups.list_all(search))}
  end

  def handle_event("delete_group", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} -> do_delete_group(id, socket)
      _ -> {:noreply, put_flash(socket, :error, "Group not found.")}
    end
  end

  defp do_delete_group(id, socket) do
    case Enum.find(socket.assigns.rows, &(&1.group.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Group not found.")}

      %{group: group} ->
        case Groups.admin_delete_group(group) do
          {:ok, :deleted} ->
            Audit.log(socket.assigns.current_user, "group.delete",
              target_type: "group",
              target_id: group.id,
              target_label: group.name
            )

            {:noreply,
             socket
             |> assign(rows: Groups.list_all(socket.assigns.search))
             |> put_flash(:info, "#{group.name} deleted.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete #{group.name}.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:56rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Manage Groups</h1>

      <form id="groups-search" phx-change="search" style="margin-bottom:0.75rem">
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search by group name…"
          phx-debounce="300"
          style="width:100%;max-width:20rem;border:1px solid var(--border);border-radius:0.35rem;padding:0.4rem 0.6rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
        />
      </form>

      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        {length(@rows)} groups
      </p>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
          <colgroup>
            <col />
            <col style="width:9rem" />
            <col style="width:6rem" />
            <col style="width:6rem" />
            <col style="width:6rem" />
            <col style="width:9rem" />
          </colgroup>
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Name</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Owner</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Members
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Invite
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for %{group: group, member_count: count, owner_username: owner} <- @rows do %>
              <tr style="border-top:1px solid var(--border-subtle)">
                <td style="padding:0.45rem 0.75rem;font-weight:500;overflow:hidden">
                  <.link
                    navigate={~p"/admin/groups/#{group}"}
                    style="text-decoration:none;color:var(--text)"
                  >
                    {group.name}
                  </.link>
                </td>
                <td style="padding:0.45rem 0.75rem;color:var(--text-muted)">{owner}</td>
                <td style="padding:0.45rem 0.75rem">{count} / {group.member_cap}</td>
                <td style="padding:0.45rem 0.75rem">
                  {if group.invite_active, do: "Active", else: "Off"}
                </td>
                <td style="padding:0.35rem 0.75rem">
                  <div style="display:flex;gap:0.35rem">
                    <.link navigate={~p"/admin/groups/#{group}"} class="btn-outline btn-xs">
                      View
                    </.link>
                    <button
                      type="button"
                      phx-click="delete_group"
                      phx-value-id={group.id}
                      data-confirm={"Delete #{group.name}? This can't be undone."}
                      class="btn-danger-outline btn-xs"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
