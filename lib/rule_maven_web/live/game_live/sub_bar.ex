defmodule RuleMavenWeb.GameLive.SubBar do
  @moduledoc """
  Persistent slim sub-bar under the game header. Three group menus
  (🎲 Play · 📚 Learn · 💬 More); Play/Learn items dispatch `open_tool`,
  More items are navigation/links. Always rendered (empty state AND
  mid-conversation) so tools stay reachable. Mobile-first: one row, three
  short pills fit 390px.
  """
  use RuleMavenWeb, :html
  alias RuleMavenWeb.GameLive.ToolRegistry

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :current_user, :map, required: true

  def sub_bar(assigns) do
    ~H"""
    <div
      class="tool-subbar"
      data-tour="tools-subbar"
      style="flex-shrink:0;display:flex;align-items:center;gap:0.4rem;padding:0.25rem 0.75rem;border-bottom:1px solid var(--border);background:var(--bg-surface);overflow-x:auto"
    >
      <.group_menu emoji="🎲" label="Play" tools={ToolRegistry.group(:play)} />
      <.group_menu emoji="📚" label="Learn" tools={ToolRegistry.group(:learn)} />
      <.more_menu
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :emoji, :string, required: true
  attr :label, :string, required: true
  attr :tools, :list, required: true

  defp group_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <summary
        class="pill-link"
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">{@emoji}</span>
        <span>{@label}</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div class="card-menu__pop">
        <button
          :for={t <- @tools}
          type="button"
          phx-click="open_tool"
          phx-value-tool={t.id}
          onclick="this.closest('details').open = false"
          class="card-menu__item"
        >
          <span aria-hidden="true">{t.emoji}</span> {t.label}
        </button>
      </div>
    </details>
    """
  end

  attr :game, :map, required: true
  attr :sources, :list, required: true
  attr :community_count, :integer, required: true
  attr :is_admin, :boolean, required: true
  attr :current_user, :map, required: true

  defp more_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <summary
        class="pill-link"
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">💬</span>
        <span>More</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div class="card-menu__pop card-menu__pop--right">
        <.link patch={~p"/games/#{@game}?start=1"} class="card-menu__item">🔍 Overview</.link>
        <.link
          :if={@community_count > 0}
          navigate={~p"/games/#{@game}/community"}
          class="card-menu__item"
        >💬 Community Q&amp;A ({@community_count})</.link>
        <%= if @sources != [] do %>
          <div class="card-menu__divider"></div>
          <div class="card-menu__label">📖 Rulebooks</div>
          <%= for src <- @sources do %>
            <%= if @is_admin and src.html_path do %>
              <.link href={~p"/rulebooks/#{src}/html"} target="_blank" class="card-menu__item">
                {src.label}
              </.link>
            <% else %>
              <div class="card-menu__item" style="cursor:default">{src.label}</div>
            <% end %>
          <% end %>
        <% end %>
        <.link
          :if={@game.bgg_id && RuleMaven.Games.Category.bgg_relevant?(@game.category)}
          href={"https://boardgamegeek.com/boardgame/#{@game.bgg_id}"}
          target="_blank"
          rel="noopener"
          class="card-menu__item"
        >🔗 View on BGG</.link>
      </div>
    </details>
    """
  end
end
