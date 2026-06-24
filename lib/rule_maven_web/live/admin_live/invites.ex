defmodule RuleMavenWeb.AdminLive.Invites do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{InviteCodes, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.game_master?(socket.assigns.current_user) do
      invite_codes = InviteCodes.list_codes()
      {:ok, assign(socket, page_title: "Invite Codes", invite_codes: invite_codes)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create_invite", %{"max_uses" => max_str}, socket) do
    max_uses = String.to_integer(max_str)
    user_id = socket.assigns.current_user.id

    case InviteCodes.create_code(user_id, max_uses: max_uses) do
      {:ok, code} ->
        codes = InviteCodes.list_codes()

        {:noreply,
         assign(socket, invite_codes: codes) |> put_flash(:info, "Created: #{code.code}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create invite code.")}
    end
  end

  def handle_event("deactivate_invite", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case InviteCodes.list_codes() |> Enum.find(&(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Invite code not found.")}

      code ->
        {:ok, _} = InviteCodes.deactivate_code(code)
        codes = InviteCodes.list_codes()
        {:noreply, assign(socket, invite_codes: codes) |> put_flash(:info, "Code deactivated.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Invite Codes</h1>

      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        Generate invite codes for new users. Share a code — they'll use it to register. ({length(
          @invite_codes
        )} codes)
      </p>

      <div style="display:flex;gap:0.5rem;align-items:end;margin-bottom:1rem">
        <div>
          <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Max uses</label>
          <input
            type="number"
            name="max_uses"
            value="1"
            min="1"
            max="100"
            form="invite-form"
            style="width:5rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text)"
          />
        </div>
        <button
          type="submit"
          form="invite-form"
          style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer"
        >Generate</button>
        <form id="invite-form" phx-submit="create_invite" style="display:none"></form>
      </div>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.8rem">
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style="padding:0.3rem 0.5rem;border-bottom:1px solid var(--border)">Code</th>
              <th style="padding:0.3rem 0.5rem;border-bottom:1px solid var(--border)">Uses</th>
              <th style="padding:0.3rem 0.5rem;border-bottom:1px solid var(--border)">Status</th>
              <th style="padding:0.3rem 0.5rem;border-bottom:1px solid var(--border)">
                Created by
              </th>
              <th style="padding:0.3rem 0.5rem;border-bottom:1px solid var(--border);width:100px">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for code <- @invite_codes do %>
              <tr style="background:var(--bg)">
                <td style="padding:0.25rem 0.5rem;border-bottom:1px solid var(--border-subtle);font-family:monospace;font-weight:600;font-size:0.8rem">
                  {code.code}
                </td>
                <td style="padding:0.25rem 0.5rem;border-bottom:1px solid var(--border-subtle)">
                  {code.use_count}/{code.max_uses}
                </td>
                <td style="padding:0.25rem 0.5rem;border-bottom:1px solid var(--border-subtle)">
                  <span style={"font-weight:600;#{if code.active, do: "color:var(--green)", else: "color:var(--text-muted)"}"}>
                    {if code.active, do: "Active", else: "Inactive"}
                  </span>
                </td>
                <td style="padding:0.25rem 0.5rem;border-bottom:1px solid var(--border-subtle);color:var(--text-muted)">
                  {code.created_by && code.created_by.username}
                </td>
                <td style="padding:0.15rem 0.5rem;border-bottom:1px solid var(--border-subtle)">
                  <%= if code.active do %>
                    <button
                      type="button"
                      phx-click="deactivate_invite"
                      phx-value-id={code.id}
                      style="background:none;border:1px solid var(--border);color:var(--text-muted);padding:0.15rem 0.35rem;border-radius:0.25rem;font-size:0.6rem;font-weight:600;cursor:pointer"
                    >Deactivate</button>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @invite_codes == [] do %>
        <p style="color:var(--text-muted);font-size:0.8rem;text-align:center;padding:1.5rem 0">
          No invite codes yet. Generate one above.
        </p>
      <% end %>
    </div>
    """
  end
end
