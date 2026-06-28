defmodule RuleMavenWeb.AdminLive.Users do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      all_users = Users.list_users()

      {:ok,
       assign(socket,
         page_title: "Manage Users",
         users: all_users,
         new_username: "",
         new_email: "",
         new_role: "player",
         temp_password: nil,
         created_username: nil
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("promote_user", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case Users.get_user(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:ok, _} = Users.update_user_role(user, "game_master")
        audit(socket, "role.promote", user, %{to: "game_master"})
        users = Users.list_users()

        {:noreply,
         assign(socket, users: users)
         |> put_flash(:info, "#{user.username} promoted to game master.")}
    end
  end

  def handle_event("demote_user", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case Users.get_user(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:ok, _} = Users.update_user_role(user, "player")
        audit(socket, "role.demote", user, %{to: "player"})
        users = Users.list_users()

        {:noreply,
         assign(socket, users: users) |> put_flash(:info, "#{user.username} demoted to player.")}
    end
  end

  def handle_event(
        "create_user",
        %{"username" => username, "email" => email, "role" => role},
        socket
      ) do
    case Users.create_user_with_temp_password(%{
           username: String.trim(username),
           email: String.trim(email),
           role: role
         }) do
      {:ok, user, password} ->
        audit(socket, "user.create", user, %{role: user.role})
        users = Users.list_users()

        {:noreply,
         assign(socket,
           users: users,
           temp_password: password,
           created_username: user.username,
           new_username: "",
           new_email: "",
           new_role: "player"
         )
         |> put_flash(:info, "Created #{user.username}")}

      {:error, changeset, _password} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "Failed: #{msg}")}
    end
  end

  def handle_event("dismiss_temp_password", _params, socket) do
    {:noreply, assign(socket, temp_password: nil, created_username: nil)}
  end

  def handle_event("form_change", params, socket) do
    socket =
      Enum.reduce([:new_username, :new_email, :new_role], socket, fn field, acc ->
        key = Atom.to_string(field)
        if Map.has_key?(params, key), do: assign(acc, field, params[key]), else: acc
      end)

    {:noreply, socket}
  end

  defp audit(socket, action, user, metadata) do
    Audit.log(socket.assigns.current_user, action,
      target_type: "user",
      target_id: user.id,
      target_label: user.username,
      metadata: metadata
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Manage Users</h1>

      <!-- Temp password display -->
      <%= if @temp_password do %>
        <div style="background:var(--bg-surface);border:2px solid var(--green);border-radius:0.5rem;padding:1rem;margin-bottom:1rem;text-align:center">
          <div style="font-size:0.85rem;font-weight:700;color:var(--text);margin-bottom:0.25rem">
            ✅ Account created: <strong>{@created_username}</strong>
          </div>
          <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
            Share this temp password with the user. They'll use it to log in.
          </p>
          <div style="display:flex;gap:0.35rem;justify-content:center;align-items:center;margin-bottom:0.75rem">
            <code style="background:var(--bg);padding:0.35rem 0.75rem;border:1px solid var(--border);border-radius:0.3rem;font-size:1rem;font-weight:700;font-family:monospace;letter-spacing:0.05em">{@temp_password}</code>
            <button
              type="button"
              id="copy-temp-password"
              phx-hook="ClipboardCopy"
              data-clipboard-text={@temp_password}
              style="background:var(--bg-subtle);border:1px solid var(--border);border-radius:0.3rem;padding:0.35rem 0.6rem;font-size:0.7rem;cursor:pointer;color:var(--text);font-weight:600"
            >📋 Copy</button>
          </div>
          <button
            type="button"
            phx-click="dismiss_temp_password"
            style="background:var(--accent);color:#fff;border:none;padding:0.3rem 1.5rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer"
          >Done</button>
        </div>
      <% end %>

      <!-- Create user form -->
      <%= if !@temp_password do %>
        <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem;margin-bottom:1rem">
          <h2 style="font-size:0.85rem;font-weight:600;color:var(--text);margin:0 0 0.5rem">
            Create New User
          </h2>
          <div phx-change="form_change" style="display:flex;gap:0.5rem;align-items:end;flex-wrap:wrap">
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Username</label>
              <input
                type="text"
                name="new_username"
                value={@new_username}
                placeholder="username"
                style="width:9rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.78rem;background:var(--bg);color:var(--text)"
              />
            </div>
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Email</label>
              <input
                type="email"
                name="new_email"
                value={@new_email}
                placeholder="user@example.com"
                style="width:12rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.78rem;background:var(--bg);color:var(--text)"
              />
            </div>
            <div>
              <label style="display:block;font-size:0.7rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Role</label>
              <select
                name="new_role"
                value={@new_role}
                style="border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.4rem;font-size:0.78rem;background:var(--bg);color:var(--text);cursor:pointer"
              >
                <option value="player">Player</option>
                <option value="game_master">Game Master</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="create_user"
              phx-value-username={@new_username}
              phx-value-email={@new_email}
              phx-value-role={@new_role}
              disabled={@new_username == "" || @new_email == ""}
              style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer;align-self:end"
            >Create &amp; Generate Password</button>
          </div>
        </div>
      <% end %>

      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        Promote players to game masters, or demote them back. ({length(@users)} users)
      </p>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
          <colgroup>
            <col style="width:9rem" />
            <col />
            <col style="width:7rem" />
            <col style="width:6rem" />
            <col style="width:9rem" />
          </colgroup>
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Username
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Email</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Role</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Joined</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for user <- @users do %>
              <tr style="border-top:1px solid var(--border-subtle)">
                <td style="padding:0.45rem 0.75rem;font-weight:500;overflow:hidden">
                  <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{user.username}</span>
                </td>
                <td style="padding:0.45rem 0.75rem;overflow:hidden">
                  <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text-muted);font-size:0.78rem">{user.email}</span>
                </td>
                <td style="padding:0.45rem 0.75rem;font-weight:600;font-size:0.78rem">
                  <span style={"#{if user.role == "game_master", do: "color:var(--accent)", else: "color:var(--text-muted)"}"}>
                    {user.role}
                  </span>
                </td>
                <td style="padding:0.45rem 0.75rem;color:var(--text-muted);font-size:0.75rem">
                  {String.slice(to_string(user.inserted_at), 0, 10)}
                </td>
                <td style="padding:0.35rem 0.75rem">
                  <div style="display:flex;gap:0.35rem">
                    <%= if user.role == "player" do %>
                      <button
                        type="button"
                        phx-click="promote_user"
                        phx-value-id={user.id}
                        style="background:none;border:1px solid var(--accent);color:var(--accent);padding:0.15rem 0.5rem;border-radius:0.25rem;font-size:0.7rem;font-weight:600;cursor:pointer"
                      >Promote</button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="demote_user"
                        phx-value-id={user.id}
                        data-confirm={"Remove game-master access from #{user.username}?"}
                        style="background:none;border:1px solid var(--border);color:var(--text-muted);padding:0.15rem 0.5rem;border-radius:0.25rem;font-size:0.7rem;font-weight:600;cursor:pointer"
                      >Demote</button>
                    <% end %>
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
