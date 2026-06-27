defmodule RuleMavenWeb.Layouts do
  use RuleMavenWeb, :html

  alias RuleMaven.Users

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app-shell">
      <header class="header">
        <div class="header-inner">
          <a href={~p"/"} class="header-brand">
            <span class="header-icon">◆</span>
            <span class="header-title">Rule <span class="header-title-accent">Maven</span></span>
          </a>
          <span class="header-tagline">rules &amp; reference assistant</span>
        </div>
      </header>

      <.flash_group flash={@flash} />

      <main class="main-content">
        <div class="container">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      style="position:fixed;top:1rem;right:1rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;min-width:20rem;max-width:24rem"
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
