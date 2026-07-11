defmodule RuleMavenWeb.SettingsLive do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Users

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: "Settings",
       profile_username: user.username,
       profile_email: user.email,
       profile_msg: nil,
       profile_error: nil,
       password_msg: nil,
       password_error: nil,
       is_admin: Users.can?(user, :admin),
       curator_stats: RuleMaven.Games.Curation.curator_stats(user.id)
     )}
  end

  @impl true
  def handle_event("update_profile", %{"username" => username, "email" => email}, socket) do
    user = socket.assigns.current_user

    case Users.update_profile(user, %{username: String.trim(username), email: String.trim(email)}) do
      {:ok, updated} ->
        {:noreply,
         assign(socket,
           profile_username: updated.username,
           profile_email: updated.email,
           profile_msg: "Profile updated.",
           profile_error: nil
         )}

      {:error, changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, profile_error: msg, profile_msg: nil)}
    end
  end

  def handle_event(
        "change_password",
        %{"current_password" => current, "new_password" => new, "confirm_password" => confirm},
        socket
      ) do
    cond do
      new != confirm ->
        {:noreply,
         assign(socket, password_error: "New passwords don't match.", password_msg: nil)}

      true ->
        user = socket.assigns.current_user

        case Users.change_password(user, current, new) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               password_msg: "Password changed.",
               password_error: nil
             )}

          {:error, reason} ->
            {:noreply, assign(socket, password_error: reason, password_msg: nil)}
        end
    end
  end

  def handle_event("profile_form_change", params, socket) do
    socket =
      Enum.reduce(
        [:profile_username, :profile_email, :current_password, :new_password, :confirm_password],
        socket,
        fn field, acc ->
          key = Atom.to_string(field)
          if Map.has_key?(params, key), do: assign(acc, field, params[key]), else: acc
        end
      )

    {:noreply,
     assign(socket, profile_msg: nil, profile_error: nil, password_msg: nil, password_error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-page" style="max-width:36rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
      <div class="mb-4">
        <.link navigate={~p"/"} class="back-link">
          &larr; Back to games
        </.link>
      </div>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.75rem 0">Profile</h2>

        <div phx-change="profile_form_change">
          <!-- Username & Email -->
          <div style="display:flex;gap:0.75rem;flex-wrap:wrap;margin-bottom:0.75rem">
            <div style="flex:1;min-width:10rem">
              <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Username</label>
              <input
                type="text"
                name="profile_username"
                value={@profile_username}
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
              />
            </div>
            <div style="flex:1;min-width:10rem">
              <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Email</label>
              <input
                type="email"
                name="profile_email"
                value={@profile_email}
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
              />
            </div>
          </div>
          <div style="display:flex;gap:0.5rem;align-items:center">
            <button
              type="button"
              phx-click="update_profile"
              phx-value-username={@profile_username}
              phx-value-email={@profile_email}
              class="btn-primary btn-sm"
            >Save Profile</button>
            <%= if @profile_msg do %>
              <span style="font-size:0.75rem;color:var(--green)">{@profile_msg}</span>
            <% end %>
            <%= if @profile_error do %>
              <span style="font-size:0.75rem;color:var(--red)">{@profile_error}</span>
            <% end %>
          </div>

          <!-- Change Password -->
          <div style="margin-top:1rem;padding-top:1rem;border-top:1px solid var(--border)">
            <h3 style="font-size:0.82rem;font-weight:600;margin:0 0 0.5rem 0">Change Password</h3>
            <form
              phx-submit="change_password"
              style="display:flex;flex-direction:column;gap:0.5rem;max-width:20rem"
            >
              <input
                type="password"
                name="current_password"
                placeholder="Current password"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
              />
              <input
                type="password"
                name="new_password"
                placeholder="New password"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
              />
              <input
                type="password"
                name="confirm_password"
                placeholder="Confirm new password"
                style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
              />
              <div style="display:flex;gap:0.5rem;align-items:center">
                <button
                  type="submit"
                  class="btn-sm"
                >Change Password</button>
                <%= if @password_msg do %>
                  <span style="font-size:0.75rem;color:var(--green)">{@password_msg}</span>
                <% end %>
                <%= if @password_error do %>
                  <span style="font-size:0.75rem;color:var(--red)">{@password_error}</span>
                <% end %>
              </div>
            </form>
          </div>
        </div>

        <div style="margin-top:1.25rem;border-top:1px solid var(--border);padding-top:1rem">
          <h3 style="font-size:0.9rem;font-weight:700;margin:0 0 0.5rem 0">Community standing</h3>
          <p style="font-size:0.82rem;color:var(--text-muted);margin:0">
            <strong style="color:var(--text)">{@curator_stats.points}</strong>
            curator points earned from votes that settled correct.
            <.link navigate={~p"/standing"} style="font-weight:600">View your standing page →</.link>
          </p>
        </div>
      </section>

      <div :if={@is_admin} class="mt-6 pt-4 border-t">
        <.link navigate={~p"/admin"} class="back-link" style="margin-bottom:0">
          Admin dashboard — LLM, BGG, and other integration settings &rarr;
        </.link>
      </div>
    </div>
    """
  end
end
