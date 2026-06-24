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
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RuleMavenWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", AuthController, :logout
    get "/games/:id/cheatsheet", CheatSheetController, :show
    get "/games/:id/cheatsheet/:version_id", CheatSheetController, :show_version

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
      live "/games/refresh", GameLive.Refresh, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/edit", GameLive.Form, :edit
      live "/games/:id/review", GameLive.Review, :index
      live "/games/:id/faq", GameLive.Faq, :index
      live "/admin", AdminLive.Index, :index
      live "/admin/db", AdminLive.Db, :index
      live "/admin/threads", AdminLive.Threads, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/invites", AdminLive.Invites, :index
      live "/settings", SettingsLive, :index
      live "/settings/usage", SettingsLive, :usage
    end
  end

  scope "/", RuleMavenWeb do
    pipe_through [:browser]

    oban_dashboard("/oban", on_mount: [RuleMavenWeb.ObanAuthHook])
  end
end
