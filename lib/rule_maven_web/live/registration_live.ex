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
  def handle_event(
        "register",
        %{"code" => code, "username" => username, "email" => email, "password" => password},
        socket
      ) do
    errors = %{}

    {errors, code_valid?} =
      case InviteCodes.validate_code(code) do
        {:ok, _} -> {errors, true}
        {:error, reason} -> {Map.put(errors, :code, reason), false}
      end

    errors = if username == "", do: Map.put(errors, :username, "Required."), else: errors
    errors = if email == "", do: Map.put(errors, :email, "Required."), else: errors

    errors =
      cond do
        password == "" ->
          Map.put(errors, :password, "Required.")

        String.length(password) < 4 ->
          Map.put(errors, :password, "Must be at least 4 characters.")

        true ->
          errors
      end

    if map_size(errors) == 0 && code_valid? do
      case Users.create_user(%{username: username, email: email, password: password}) do
        {:ok, user} ->
          InviteCodes.use_code(code)
          send_confirmation_email(user)
          token = Phoenix.Token.sign(socket, "auto-login", user.id)

          {:noreply,
           socket
           |> assign(submitted: true)
           |> redirect(to: "/auto-login?token=#{token}")}

        {:error, changeset} ->
          db_errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
            |> Enum.reduce(errors, fn {field, msgs}, acc ->
              Map.put(acc, field, List.first(msgs))
            end)

          {:noreply,
           assign(socket, errors: db_errors, invite_code: code, username: username, email: email)}
      end
    else
      {:noreply,
       assign(socket, errors: errors, invite_code: code, username: username, email: email)}
    end
  end

  # Mail the email-confirmation link. Best-effort: a mail failure must not block
  # registration (the user can re-request confirmation later).
  defp send_confirmation_email(user) do
    Users.deliver_user_confirmation_instructions(
      user,
      &(RuleMavenWeb.Endpoint.url() <> "/confirm/" <> &1)
    )
  rescue
    _ -> :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:24rem;margin:3rem auto;padding:0 1rem">
      <div style="text-align:center;margin-bottom:1.5rem">
        <div style="font-size:2.5rem;margin-bottom:0.4rem">◆</div>
        <h1 style="font-size:1.5rem;font-weight:700;color:var(--text)">Join Rule Maven</h1>
        <p style="font-size:0.85rem;color:var(--text-secondary);margin-top:0.4rem;line-height:1.5">
          Ask rules questions about your games and get instant, cited answers straight from the rulebook.
        </p>
        <p style="font-size:0.78rem;color:var(--text-muted);margin-top:0.5rem">
          Registration requires an invite code.
        </p>
      </div>

      <form phx-submit="register" style="display:flex;flex-direction:column;gap:0.75rem">
        <div>
          <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Invite Code</label>
          <input
            type="text"
            name="code"
            value={@invite_code}
            autofocus={@invite_code == ""}
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
            autofocus={@invite_code != ""}
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
            placeholder="Min 4 characters"
            style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.45rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
          />
          <%= if @errors[:password] do %>
            <p style="font-size:0.7rem;color:var(--red);margin-top:0.15rem">{@errors[:password]}</p>
          <% end %>
        </div>

        <button
          type="submit"
          disabled={@submitted}
          class="btn-primary"
          style="margin-top:0.25rem"
        >
          Create Account
        </button>
      </form>

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
