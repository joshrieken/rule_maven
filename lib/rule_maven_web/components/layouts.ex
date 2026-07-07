defmodule RuleMavenWeb.Layouts do
  use RuleMavenWeb, :html

  alias RuleMaven.Users

  embed_templates "layouts/*"

  @doc """
  The live layout (wired up via `layout: {RuleMavenWeb.Layouts, :app}` in the
  `live_view` macro, see lib/rule_maven_web.ex). The real app shell (header,
  nav, drawer, admin panel) lives in the root layout (root.html.heex) and is
  rendered once per dead render — it doesn't need to be live-reactive. This
  layout's only job is to make `flash_group` re-render on every connected
  LiveView update, since the root layout's own flash_group (kept for
  controller-rendered pages) never re-renders after the WebSocket connects. It
  renders no visual chrome of its own so pages stay pixel-identical;
  flash_group is fixed-positioned so its location in the DOM doesn't matter.

  Note: this is invoked directly by `Phoenix.LiveView.Renderer` via
  `Phoenix.Template.render/4` (matched by function name against the layout
  template atom), not as a `<Layouts.app>` component call — so it receives
  `@inner_content` (like root.html.heex does), not a slot.
  """
  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    {@inner_content}
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      style="position:fixed;top:1rem;left:50%;transform:translateX(-50%);z-index:9999;display:flex;flex-direction:column;gap:0.5rem;width:min(24rem,calc(100vw - 2rem));align-items:center"
    >
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="flash-info"
        role="alert"
        class="alert alert-info w-80 sm:w-96"
        phx-hook="FlashAutoHide"
        data-flash-duration="4000"
      >
        <span>{msg}</span>
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="flash-error"
        role="alert"
        class="alert alert-error w-80 sm:w-96"
        phx-hook="FlashAutoHide"
        data-flash-duration="6000"
      >
        <span>{msg}</span>
      </div>
    </div>
    """
  end

  @doc """
  Cache-busting version for a static asset, derived from the file's mtime.
  Static assets are served un-digested with `cache-control: public` (no
  max-age), so browsers heuristic-cache them and a normal refresh replays a
  stale copy — and service workers key their cache by full URL (Safari's hard
  refresh doesn't bypass a controlling worker's HTTP cache either). Changing
  the query string on every edit sidesteps every cache layer. One File.stat
  per dead render is negligible.
  """
  def asset_version(rel_path) do
    path = Path.join(:code.priv_dir(:rule_maven), "static/#{rel_path}")

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> Integer.to_string(mtime, 36)
      _ -> "0"
    end
  end

  def css_version, do: asset_version("assets/css/app.css")

  def js_version, do: asset_version("assets/js/app.js")

  def current_user(conn_or_assigns) do
    case conn_or_assigns do
      %Plug.Conn{private: %{plug_session: session}} ->
        case session[:user_id] || session["user_id"] do
          nil -> nil
          user_id -> Users.get_user(user_id)
        end

      _ ->
        nil
    end
  end
end
