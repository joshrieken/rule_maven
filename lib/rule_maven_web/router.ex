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

    get "/help", PageController, :help
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", AuthController, :logout
    get "/reset-password", PasswordResetController, :new
    post "/reset-password", PasswordResetController, :create
    get "/reset-password/:token", PasswordResetController, :edit
    post "/reset-password/:token", PasswordResetController, :update
    get "/magic-link", MagicLinkController, :new
    post "/magic-link", MagicLinkController, :create
    get "/magic-link/:token", MagicLinkController, :consume
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

    # One live_session for every logged-in LiveView, admin or not. LiveView can
    # only reuse the open socket when both routes share a live_session; across a
    # boundary it does a full HTTP page load. Admin pages used to sit in their
    # own `live_session :admin`, so Prepare's back arrow (and every other link
    # between an admin page and a user-facing one) reloaded the browser — the
    # page visibly blanked and the games list re-fetched.
    #
    # The admin gate did not move to mount/handle_params, where it would only be
    # advisory: `UserLiveAuth.admin_view?/1` names the admin LiveViews and the
    # `:app` hook halts a non-admin before mount, then re-checks admin standing
    # before every event, so a demoted admin's open socket still can't fire
    # save_game/delete_version/set_active_version.
    live_session :app,
      on_mount: [{RuleMavenWeb.UserLiveAuth, :app}],
      session: {RuleMavenWeb.UserLiveAuth, :get_session, []} do
      # NOTE: `/games/new` (literal) MUST be declared before `/games/:id`
      # (dynamic) — Phoenix's router matches top-down in declaration order, not
      # by specificity. Getting that order wrong makes `/games/:id`
      # (GameLive.Show) swallow "/games/new" with id="new" before Form ever
      # sees it.
      live "/games/new", GameLive.Form, :new
      live "/games/:id/edit", GameLive.Form, :edit
      live "/games/:id/review", GameLive.Review, :index
      live "/games/:id/prepare", GameLive.Prepare, :index

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
      live "/admin/groups", AdminLive.Groups, :index
      live "/admin/groups/:token", AdminLive.GroupShow, :show
      live "/admin/invites", AdminLive.Invites, :index
      live "/admin/catalog", AdminLive.Catalog, :index
      live "/admin/themes", AdminLive.Themes, :index
      live "/admin/requests", AdminLive.Requests, :index
      live "/admin/flags", AdminLive.Flags, :index
      live "/admin/llm", AdminLive.Llm, :index
      live "/admin/embeddings", AdminLive.Embeddings, :index
      live "/admin/automation", AdminLive.Automation, :index
      live "/admin/bgg", AdminLive.Bgg, :index
      live "/admin/prompts", AdminLive.Prompts, :index

      live "/", GameLive.Index, :index
      live "/games/import", GameLive.Import, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/community", GameLive.Community, :index
      # Legacy URL for old bookmarks/links — same page.
      live "/games/:id/faq", GameLive.Community, :index
      live "/settings", SettingsLive, :index
      live "/standing", StandingLive, :index

      # NOTE: "/groups/join/:code" (literal prefix) MUST be declared before
      # "/groups/:token" (dynamic) for the same reason as "/games/new" above —
      # otherwise GroupLive.Show would swallow "/groups/join/XYZ" with
      # token="join" before Join ever sees it.
      live "/groups", GroupLive.Index, :index
      live "/groups/join/:code", GroupLive.Join, :join
      live "/groups/:token", GroupLive.Show, :show
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
