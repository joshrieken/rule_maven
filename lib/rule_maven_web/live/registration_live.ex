defmodule RuleMavenWeb.RegistrationLive do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, InviteCodes}

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       assign(socket,
         invite_code: code,
         username: "",
         email: "",
         password: "",
         errors: %{},
         submitted: false
       )}
    end
  end

  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       assign(socket,
         invite_code: "",
         username: "",
         email: "",
         password: "",
         errors: %{},
         submitted: false
       )}
    end
  end

  @impl true
  def handle_event("validate_code", %{"code" => code}, socket) do
    case InviteCodes.validate_code(code) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           invite_code: code,
           errors: Map.delete(socket.assigns.errors, :code)
         )}

      {:error, reason} ->
        {:noreply, assign(socket, invite_code: code, errors: %{code: reason})}
    end
  end

  @impl true
  def handle_event(
        "register",
        %{"username" => username, "email" => email, "password" => password, "code" => code},
        socket
      ) do
    errors = %{}

    {errors, code_valid?} =
      case InviteCodes.validate_code(code) do
        {:ok, _} -> {errors, true}
        {:error, reason} -> {Map.put(errors, :code, reason), false}
      end

    errors =
      if username == "" do
        Map.put(errors, :username, "Username is required.")
      else
        errors
      end

    errors =
      if email == "" do
        Map.put(errors, :email, "Email is required.")
      else
        errors
      end

    errors =
      cond do
        password == "" ->
          Map.put(errors, :password, "Password is required.")

        String.length(password) < 4 ->
          Map.put(errors, :password, "Password must be at least 4 characters.")

        true ->
          errors
      end

    if map_size(errors) == 0 && code_valid? do
      case Users.create_user(%{username: username, email: email, password: password}) do
        {:ok, _user} ->
          InviteCodes.use_code(code)

          socket =
            socket
            |> put_flash(:info, "Account created! You can now log in.")
            |> push_navigate(to: ~p"/login")

          {:noreply, assign(socket, submitted: true)}

        {:error, changeset} ->
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
            |> Enum.reduce(errors, fn {field, msgs}, acc ->
              Map.put(acc, field, List.first(msgs))
            end)

          {:noreply, assign(socket, errors: errors)}
      end
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  @impl true
  def handle_event("form_change", params, socket) do
    socket =
      Enum.reduce([:code, :username, :email, :password], socket, fn field, acc ->
        if Map.has_key?(params, to_string(field)) do
          assign(acc, field, params[to_string(field)])
        else
          acc
        end
      end)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:24rem;margin:3rem auto;padding:0 1rem">
      <div style="text-align:center;margin-bottom:1.5rem">
        <div style="font-size:2.5rem;margin-bottom:0.4rem">◆</div>
        <h1 style="font-size:1.5rem;font-weight:700;color:var(--text)">Join Rule Maven</h1>
        <p style="font-size:0.85rem;color:var(--text-secondary);margin-top:0.4rem;line-height:1.5">
          Ask rules questions about your board games and get instant, cited answers from the rulebook.
        </p>
        <p style="font-size:0.78rem;color:var(--text-muted);margin-top:0.5rem">
          Registration requires an invite code.
        </p>
      </div>

      <div phx-change="form_change" style="display:flex;flex-direction:column;gap:0.75rem">
        <div>
          <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Invite Code</label>
          <input
            type="text"
            name="code"
            value={@invite_code}
            placeholder="Enter your invite code"
            style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.45rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
            autocomplete="off"
          />
          <%= if @errors[:code] do %>
            <p style="font-size:0.7rem;color:var(--red);margin-top:0.15rem">{@errors[:code]}</p>
          <% end %>
        </div>

        <div>
          <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Username</label>
          <input
            type="text"
            name="username"
            value={@username}
            placeholder="Choose a username"
            style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.45rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
            autocomplete="off"
          />
          <%= if @errors[:username] do %>
            <p style="font-size:0.7rem;color:var(--red);margin-top:0.15rem">{@errors[:username]}</p>
          <% end %>
        </div>

        <div>
          <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Email</label>
          <input
            type="email"
            name="email"
            value={@email}
            placeholder="you@example.com"
            style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.45rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
            autocomplete="off"
          />
          <%= if @errors[:email] do %>
            <p style="font-size:0.7rem;color:var(--red);margin-top:0.15rem">{@errors[:email]}</p>
          <% end %>
        </div>

        <div>
          <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Password</label>
          <input
            type="password"
            name="password"
            value={@password}
            placeholder="Min 4 characters"
            style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.45rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
          />
          <%= if @errors[:password] do %>
            <p style="font-size:0.7rem;color:var(--red);margin-top:0.15rem">{@errors[:password]}</p>
          <% end %>
        </div>

        <button
          type="button"
          phx-click="register"
          phx-value-code={@invite_code}
          phx-value-username={@username}
          phx-value-email={@email}
          phx-value-password={@password}
          disabled={@submitted}
          style="background:var(--accent);color:#fff;border:none;padding:0.55rem;border-radius:0.375rem;font-size:0.85rem;font-weight:600;cursor:pointer;margin-top:0.25rem"
        >
          Create Account
        </button>
      </div>

      <div style="text-align:center;margin-top:1rem">
        <.link
          navigate={~p"/login"}
          style="color:var(--text-muted);font-size:0.78rem;text-decoration:none"
        >
          Already have an account? Log in
        </.link>
      </div>
    </div>
    """
  end
end
