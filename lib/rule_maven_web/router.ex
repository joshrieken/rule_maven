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
    get "/auto-login", AuthController, :auto_login
    get "/confirm/:token", ConfirmationController, :confirm
    get "/games/:id/cheatsheet", CheatSheetController, :show
    get "/games/:id/cheatsheet/:version_id", CheatSheetController, :show_version
    # Extracted-text HTML view, admin-gated (rulebooks may be copyrighted; the
    # original PDF is never served over HTTP).
    get "/rulebooks/:id/html", RulebookController, :html
    # Theme picker pings this on change so we can track theme usage.
    post "/theme-events", MetricsController, :theme

    live_session :public,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :public}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      live "/register", RegistrationLive, :index
    end

    live_session :default,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :default}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      live "/", GameLive.Index, :index
      live "/games/new", GameLive.Form, :new
      live "/games/import", GameLive.Import, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/edit", GameLive.Form, :edit
      live "/games/:id/faq", GameLive.Faq, :index
      live "/settings", SettingsLive, :index
      live "/settings/usage", SettingsLive, :usage
    end

    live_session :admin,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :admin}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      # Admin-only review surface. Kept in the :admin session so the on_mount
      # hook halts non-admins before mount — the in-mount redirect alone is
      # client-side and does not stop forged events on a raw socket.
      live "/games/:id/review", GameLive.Review, :index
      live "/admin", AdminLive.Index, :index
      live "/admin/db", AdminLive.Db, :index
      live "/admin/security", AdminLive.Security, :index
      live "/admin/questions", AdminLive.Questions, :index
      live "/admin/threads", AdminLive.Threads, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/invites", AdminLive.Invites, :index
      live "/admin/catalog", AdminLive.Catalog, :index
      live "/admin/themes", AdminLive.Themes, :index
      live "/admin/requests", AdminLive.Requests, :index
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
