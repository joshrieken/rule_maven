defmodule RuleMavenWeb.UserLiveAuth do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, attach_hook: 4]
  import Plug.Conn, only: [get_session: 2]

  alias RuleMaven.Users
  alias RuleMaven.Users.AuthCache

  # LiveViews that only an admin may mount. This list is the admin gate: it used
  # to be a separate `live_session :admin`, but a live_session boundary can't be
  # crossed on the existing socket — `navigate` between one and a :default view
  # forces a full page reload, which users saw as Prepare's back arrow blanking
  # the page and re-fetching the games list. Everything now shares one
  # live_session and the gate moved in here, where it still runs before mount
  # (halting a non-admin on a raw socket) and again before every event.
  @admin_views [
    RuleMavenWeb.GameLive.Review,
    RuleMavenWeb.GameLive.Prepare,
    RuleMavenWeb.GameLive.Form
  ]

  # LiveViews whose mount already requires :superadmin (raw credentials, DB
  # writes, security config, feature flags, system-wide LLM/prompt behavior).
  # A plain :admin_reauth check would let a demoted super_admin keep firing
  # these pages' mutating events on a stale open socket until the page next
  # reloads — reauth_event/4 below checks against this list instead of
  # blanket :admin so the per-event re-check matches what mount required.
  @superadmin_views [
    RuleMavenWeb.AdminLive.Llm,
    RuleMavenWeb.AdminLive.Bgg,
    RuleMavenWeb.AdminLive.Security,
    RuleMavenWeb.AdminLive.Flags,
    RuleMavenWeb.AdminLive.Embeddings,
    RuleMavenWeb.AdminLive.Prompts,
    RuleMavenWeb.AdminLive.Automation,
    RuleMavenWeb.AdminLive.Db
  ]

  def on_mount(:app, _params, session, socket) do
    case active_user(session) do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user ->
        cond do
          not admin_view?(socket.view) ->
            {:cont, mount_user(socket, user, session)}

          Users.can?(user, :admin) ->
            # A LiveView socket outlives its mount: if an admin is demoted or
            # suspended mid-session, the connection stays open and could keep
            # firing mutating events. Re-verify standing before EVERY event so
            # revocation takes effect on the next interaction, uniformly
            # across all admin LiveViews without each having to remember its
            # own per-event check. Pages gated to :superadmin at mount get the
            # same bar re-checked here, not just :admin.
            required = if superadmin_view?(socket.view), do: :superadmin, else: :admin

            socket
            |> mount_user(user, session)
            |> attach_hook(:admin_reauth, :handle_event, &reauth_event(required, &1, &2, &3))
            |> then(&{:cont, &1})

          true ->
            {:halt, redirect(socket, to: "/")}
        end
    end
  end

  def on_mount(:public, _params, session, socket) do
    {:cont, assign(socket, :current_user, active_user(session))}
  end

  @doc """
  Whether `view` may only be mounted by an admin. Public so the router's
  live_session can be audited against it.
  """
  def admin_view?(view) do
    view in @admin_views or
      String.starts_with?(Atom.to_string(view), "Elixir.RuleMavenWeb.AdminLive.")
  end

  @doc "Whether `view` requires :superadmin (checked at mount by the view itself)."
  def superadmin_view?(view), do: view in @superadmin_views

  # A socket outlives its mount, so a user suspended (or force-logged-out) after
  # connecting would otherwise keep a live session with full event access.
  # Re-verify suspension/session validity before EVERY event so revocation takes
  # effect on the next interaction. `logged_in_at` is stashed on the socket (it
  # only ever comes from the session, not the DB) so the hook can re-run
  # `session_valid?/2` without threading the session through.
  defp mount_user(socket, user, session) do
    logged_in_at = session[:logged_in_at] || session["logged_in_at"]

    socket
    |> assign(:logged_in_at, logged_in_at)
    |> assign(:current_user, user)
    |> attach_hook(:suspension_reauth, :handle_event, &default_reauth_event/3)
  end

  # Re-checks standing on each event, against `required` (:admin
  # or :superadmin — whichever the view's own mount enforced). Halts
  # (redirects) the moment a once-qualified user loses the capability or is
  # suspended, so a stale socket can't keep mutating after revocation.
  # Standing comes from AuthCache-backed `standing_user/1` (invalidated on
  # every revocation write, 5s TTL worst case) rather than a per-event DB
  # read — the socket's assigned user is still refreshed on every DB fetch.
  defp reauth_event(required, _event, _params, socket) do
    user = socket.assigns[:current_user]

    with %{id: id} <- user,
         {source, fresh} when not is_nil(fresh) <- standing_user(id),
         false <- Users.suspended?(fresh),
         true <- Users.can?(fresh, required) do
      {:cont, maybe_refresh_user(socket, source, fresh)}
    else
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  # Re-checks suspension/session standing on each event of a
  # :default-session LiveView. Halts (redirects to login) the moment an
  # open socket's user is suspended or their session is invalidated
  # (force-logout), so a stale socket can't keep firing events after
  # revocation. Standing comes from AuthCache-backed `standing_user/1`
  # (invalidated on every revocation write, 5s TTL worst case) rather than a
  # per-event DB read.
  defp default_reauth_event(_event, _params, socket) do
    user = socket.assigns[:current_user]
    logged_in_at = socket.assigns[:logged_in_at]

    with %{id: id} <- user,
         {source, fresh} when not is_nil(fresh) <- standing_user(id),
         false <- Users.suspended?(fresh),
         true <- Users.session_valid?(fresh, logged_in_at) do
      {:cont, maybe_refresh_user(socket, source, fresh)}
    else
      _ -> {:halt, redirect(socket, to: "/login")}
    end
  end

  # Resolves the user for a standing check, via the short-TTL AuthCache.
  # Returns `{:cache | :db, user_or_nil}` so callers know whether the struct
  # is fresh. Only found users are cached: a deleted user's socket re-querying
  # for a few events is cheap, and a nil entry would mask a re-created row.
  defp standing_user(id) do
    case AuthCache.get(id) do
      {:ok, user} ->
        {:cache, user}

      :miss ->
        user = Users.get_user(id)
        if user, do: AuthCache.put(id, user)
        {:db, user}
    end
  end

  # Only a DB fetch may overwrite :current_user. A cached struct (up to 5s
  # old) is good enough to *check standing*, but assigning it back could
  # clobber a fresher struct the LiveView itself just assigned (e.g. right
  # after a profile edit or tour completion).
  defp maybe_refresh_user(socket, :db, fresh), do: assign(socket, :current_user, fresh)
  defp maybe_refresh_user(socket, :cache, _fresh), do: socket

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
