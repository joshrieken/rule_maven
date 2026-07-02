defmodule RuleMavenWeb.UserLiveAuth do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, attach_hook: 4]
  import Plug.Conn, only: [get_session: 2]

  alias RuleMaven.Users

  def on_mount(:default, _params, session, socket) do
    case active_user(session) do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user ->
        # Mirrors the :admin hook below: a socket outlives its mount, so a
        # user suspended (or force-logged-out) after connecting would
        # otherwise keep a live session with full event access. Re-verify
        # suspension/session validity before EVERY event so revocation takes
        # effect on the next interaction, uniformly across all :default
        # LiveViews. `logged_in_at` is stashed on the socket (it only ever
        # comes from the session, not the DB) so the hook can re-run
        # `session_valid?/2` without threading the session through.
        logged_in_at = session[:logged_in_at] || session["logged_in_at"]

        socket =
          socket
          |> assign(:logged_in_at, logged_in_at)
          |> attach_hook(:suspension_reauth, :handle_event, &default_reauth_event/3)

        {:cont, assign(socket, :current_user, user)}
    end
  end

  def on_mount(:admin, _params, session, socket) do
    case active_user(session) do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user ->
        if Users.can?(user, :admin) do
          # A LiveView socket outlives its mount: if an admin is demoted or
          # suspended mid-session, the connection stays open and could keep
          # firing mutating events. Re-verify admin standing before EVERY event
          # so revocation takes effect on the next interaction, uniformly across
          # all :admin LiveViews (DB Admin, Security, etc.) without each having
          # to remember its own per-event check.
          socket = attach_hook(socket, :admin_reauth, :handle_event, &reauth_event/3)
          {:cont, assign(socket, :current_user, user)}
        else
          {:halt, redirect(socket, to: "/")}
        end
    end
  end

  def on_mount(:public, _params, session, socket) do
    {:cont, assign(socket, :current_user, active_user(session))}
  end

  # Re-checks admin standing from the DB on each event. Halts (redirects) the
  # moment a once-admin loses the capability or is suspended, so a stale socket
  # can't keep mutating after revocation. Re-fetches fresh — the socket's
  # assigned user is a snapshot from mount.
  defp reauth_event(_event, _params, socket) do
    user = socket.assigns[:current_user]

    with %{id: id} <- user,
         fresh when not is_nil(fresh) <- Users.get_user(id),
         false <- Users.suspended?(fresh),
         true <- Users.can?(fresh, :admin) do
      {:cont, assign(socket, :current_user, fresh)}
    else
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  # Re-checks suspension/session standing from the DB on each event of a
  # :default-session LiveView. Halts (redirects to login) the moment an
  # open socket's user is suspended or their session is invalidated
  # (force-logout), so a stale socket can't keep firing events after
  # revocation. Re-fetches fresh — the socket's assigned user is a snapshot
  # from mount.
  defp default_reauth_event(_event, _params, socket) do
    user = socket.assigns[:current_user]
    logged_in_at = socket.assigns[:logged_in_at]

    with %{id: id} <- user,
         fresh when not is_nil(fresh) <- Users.get_user(id),
         false <- Users.suspended?(fresh),
         true <- Users.session_valid?(fresh, logged_in_at) do
      {:cont, assign(socket, :current_user, fresh)}
    else
      _ -> {:halt, redirect(socket, to: "/login")}
    end
  end

  # Resolves the session's user, treating a suspended account or a session
  # revoked by force-logout as logged out.
  defp active_user(session) do
    case session[:user_id] || session["user_id"] do
      nil ->
        nil

      user_id ->
        logged_in_at = session[:logged_in_at] || session["logged_in_at"]

        case RuleMaven.Users.get_user(user_id) do
          nil ->
            nil

          user ->
            cond do
              RuleMaven.Users.suspended?(user) -> nil
              not RuleMaven.Users.session_valid?(user, logged_in_at) -> nil
              true -> user
            end
        end
    end
  end

  def get_session(conn) do
    %{
      "user_id" => get_session(conn, :user_id),
      "logged_in_at" => get_session(conn, :logged_in_at)
    }
  end
end
