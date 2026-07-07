defmodule RuleMavenWeb.Router do
  use RuleMavenWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RuleMavenWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug RuleMavenWeb.AuthPlug
    plug :put_dyk_seed
  end

  # Fresh per-page-load seed for the "Did you know?" card. Baked into the
  # session (and thus data-phx-session) on each GET, so the dead render and the
  # connected LiveView mount pick the SAME fact — no flicker, no layout shift —
  # while a real refresh re-rolls it for variety.
  defp put_dyk_seed(conn, _opts) do
    Plug.Conn.put_session(conn, :dyk_seed, :rand.uniform(1_000_000_000))
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RuleMavenWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", AuthController, :logout
    get "/reset-password", PasswordResetController, :new
    post "/reset-password", PasswordResetController, :create
    get "/reset-password/:token", PasswordResetController, :edit
    post "/reset-password/:token", PasswordResetController, :update
    get "/auto-login", AuthController, :auto_login
    get "/confirm/:token", ConfirmationController, :confirm
    get "/games/:id/cheatsheet", CheatSheetController, :show
    get "/games/:id/cheatsheet/:version_id", CheatSheetController, :show_version
    # Extracted-text HTML view, admin-gated (rulebooks may be copyrighted; the
    # original PDF is never served over HTTP).
    get "/rulebooks/:id/html", RulebookController, :html
    # Original PDF, same admin gate — rendered inline in the browser's viewer.
    get "/rulebooks/:id/pdf", RulebookController, :pdf
    # Theme picker pings this on change so we can track theme usage.
    post "/theme-events", MetricsController, :theme

    live_session :public,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :public}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      live "/register", RegistrationLive, :index
    end

    live_session :admin,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :admin}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      # Admin-only review surface. Kept in the :admin session so the on_mount
      # hook halts non-admins before mount — the in-mount redirect alone is
      # client-side and does not stop forged events on a raw socket.
      live "/games/:id/review", GameLive.Review, :index
      live "/games/:id/prepare", GameLive.Prepare, :index
      # Admin-only editor. Was in :default (mount/handle_params gated admins
      # only, but that check never re-ran on handle_event) so a demoted admin
      # kept a live socket that could still fire save_game/delete_version/
      # set_active_version until reconnect. Moved here so the :admin session's
      # per-event `reauth_event` hook re-checks admin standing on every event,
      # matching Review/Prepare. Cross-boundary live_navigate from :default
      # views (Index, Show) into these routes now does a full page reload
      # instead of a connected transition — functionally fine, and this
      # codebase already round-trips this exact boundary the other way
      # (Prepare/Requests, both :admin, already `navigate` into this route
      # when it was :default).
      #
      # NOTE: `/games/new` (literal) MUST be declared before `/games/:id`
      # (dynamic, see the :default scope below) — Phoenix's router matches
      # top-down in declaration order, not by specificity, so this whole
      # :admin scope is deliberately placed ahead of :default in this file.
      # Getting that order wrong makes `/games/:id` (GameLive.Show) swallow
      # "/games/new" with id="new" before Form ever sees it.
      live "/games/new", GameLive.Form, :new
      live "/games/:id/edit", GameLive.Form, :edit
      live "/admin", AdminLive.Index, :index
      live "/admin/db", AdminLive.Db, :index
      live "/admin/security", AdminLive.Security, :index
      live "/admin/health", AdminLive.Health, :index
      live "/admin/takedowns", AdminLive.Takedowns, :index
      live "/admin/questions", AdminLive.Questions, :index
      live "/admin/moderation", AdminLive.Moderation, :index
      live "/admin/audit", AdminLive.Audit, :index
      live "/admin/usage", AdminLive.Usage, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/invites", AdminLive.Invites, :index
      live "/admin/catalog", AdminLive.Catalog, :index
      live "/admin/themes", AdminLive.Themes, :index
      live "/admin/requests", AdminLive.Requests, :index
    end

    live_session :default,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :default}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      live "/", GameLive.Index, :index
      live "/games/import", GameLive.Import, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/faq", GameLive.Faq, :index
      live "/settings", SettingsLive, :index
      live "/settings/usage", SettingsLive, :usage
      live "/standing", StandingLive, :index
    end
  end

  scope "/", RuleMavenWeb do
    pipe_through [:browser]

    oban_dashboard("/oban", on_mount: [RuleMavenWeb.ObanAuthHook])
  end

  # Preview sent emails in dev (Local adapter stores them in memory).
  if Application.compile_env(:rule_maven, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
