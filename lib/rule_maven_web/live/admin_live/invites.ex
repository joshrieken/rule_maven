defmodule RuleMavenWeb.AdminLive.Invites do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, InviteCodes, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
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
    with {max_uses, ""} when max_uses >= 1 and max_uses <= 1000 <- Integer.parse(max_str),
         user_id <- socket.assigns.current_user.id,
         {:ok, code} <- InviteCodes.create_code(user_id, max_uses: max_uses) do
      Audit.log(socket.assigns.current_user, "invite.create",
        target_type: "invite_code",
        target_id: code.id,
        target_label: code.code,
        metadata: %{"max_uses" => max_uses}
      )

      codes = InviteCodes.list_codes()
      {:noreply, assign(socket, invite_codes: codes) |> put_flash(:info, "Created: #{code.code}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid max uses (1–1000).")}
    end
  end

  def handle_event("deactivate_invite", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str),
         code when not is_nil(code) <- InviteCodes.list_codes() |> Enum.find(&(&1.id == id)),
         {:ok, _} <- InviteCodes.deactivate_code(code) do
      Audit.log(socket.assigns.current_user, "invite.deactivate",
        target_type: "invite_code",
        target_id: code.id,
        target_label: code.code
      )

      codes = InviteCodes.list_codes()
      {:noreply, assign(socket, invite_codes: codes) |> put_flash(:info, "Code deactivated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invite code not found.")}
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
            max="1000"
            form="invite-form"
            style="width:5rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text)"
          />
        </div>
        <button
          type="submit"
          form="invite-form"
          class="btn-primary btn-xs"
        >Generate</button>
        <form id="invite-form" phx-submit="create_invite" style="display:none"></form>
      </div>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
          <colgroup>
            <col style="width:10rem" />
            <col style="width:5rem" />
            <col style="width:6rem" />
            <col />
            <col style="width:13rem" />
          </colgroup>
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Code</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Uses</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Status</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Created by
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for code <- @invite_codes do %>
              <tr style="border-top:1px solid var(--border-subtle)">
                <td style="padding:0.45rem 0.75rem;font-family:monospace;font-weight:600;font-size:0.78rem">
                  {code.code}
                </td>
                <td style="padding:0.45rem 0.75rem;font-size:0.78rem;color:var(--text-secondary)">
                  {code.use_count}/{code.max_uses}
                </td>
                <td style="padding:0.45rem 0.75rem">
                  <span style={"font-size:0.75rem;font-weight:600;#{if code.active, do: "color:var(--green)", else: "color:var(--text-muted)"}"}>
                    {if code.active, do: "Active", else: "Inactive"}
                  </span>
                </td>
                <td style="padding:0.45rem 0.75rem;color:var(--text-muted);font-size:0.78rem;overflow:hidden">
                  <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{code.created_by &&
                    code.created_by.username}</span>
                </td>
                <td style="padding:0.35rem 0.75rem">
                  <div style="display:flex;gap:0.35rem;align-items:center;flex-wrap:wrap">
                    <%= if code.active do %>
                      <button
                        type="button"
                        onclick={"navigator.clipboard.writeText(window.location.origin + '/register?code=#{code.code}').then(() => { this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Copy link', 1500) })"}
                        class="btn-outline btn-xs"
                        style="white-space:nowrap"
                      >Copy link</button>
                      <button
                        type="button"
                        phx-click="deactivate_invite"
                        phx-value-id={code.id}
                        class="btn-xs"
                        style="white-space:nowrap"
                      >Deactivate</button>
                    <% end %>
                  </div>
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
