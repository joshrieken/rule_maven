defmodule RuleMavenWeb.GameLive.SubBar do
  @moduledoc """
  Persistent slim sub-bar under the game header. Three group menus
  (🎲 Play · 📚 Learn · 💬 More); Play/Learn items dispatch `open_tool`,
  More items are navigation/links. Always rendered (empty state AND
  mid-conversation) so tools stay reachable. Mobile-first: one row, three
  short pills fit 390px.
  """
  use RuleMavenWeb, :html
  alias RuleMaven.CheatSheet
  alias RuleMavenWeb.GameLive.ToolRegistry

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  # False when rendered on another LiveView (community): Overview must then be
  # a full navigate — patching across LiveViews crashes.
  attr :on_game_page, :boolean, default: true

  @doc """
  Renders the three group menus (Play / Learn / More) inline. Meant to sit in
  the game header row beside the title — no full-width bar, no overflow (an
  overflow container clips the absolutely-positioned dropdowns). Mobile-first:
  short pills that wrap under the title on narrow screens.
  """
  def sub_bar(assigns) do
    ~H"""
    <div
      class="tool-subbar"
      data-tour="tools-subbar"
      style="display:inline-flex;align-items:center;gap:0.3rem;flex-shrink:0;flex-wrap:wrap"
    >
      <.group_menu emoji="🎲" label="Play" tools={ToolRegistry.group(:play)} />
      <.group_menu emoji="📚" label="Learn" tools={ToolRegistry.group(:learn)} />
      <.more_menu
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        on_game_page={@on_game_page}
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
        title={@label}
        aria-label={@label}
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">{@emoji}</span>
        <span class="pill-label">{@label}</span>
        <span class="pill-caret" style="font-size:0.6rem;opacity:0.6">▾</span>
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
  attr :on_game_page, :boolean, required: true

  defp more_menu(assigns) do
    ~H"""
    <details class="card-menu" style="flex-shrink:0">
      <summary
        class="pill-link"
        title="More"
        aria-label="More"
        style="cursor:pointer;list-style:none;gap:0.25rem;user-select:none;font-weight:600"
      >
        <span aria-hidden="true">💬</span>
        <span class="pill-label">More</span>
        <span class="pill-caret" style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div class="card-menu__pop card-menu__pop--right">
        <.link :if={@on_game_page} patch={~p"/games/#{@game}?start=1"} class="card-menu__item">
          🔍 Overview
        </.link>
        <.link :if={!@on_game_page} navigate={~p"/games/#{@game}?start=1"} class="card-menu__item">
          🔍 Overview
        </.link>
        <.link
          :if={@community_count > 0}
          navigate={~p"/games/#{@game}/community"}
          class="card-menu__item"
        >💬 Community Q&amp;A ({@community_count})</.link>
        <%= if Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil)) do %>
          <.link href={~p"/games/#{@game}/cheatsheet"} target="_blank" class="card-menu__item">
            📋 Cheat Sheet
          </.link>
        <% end %>
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
        <%!-- Admin actions live here too: on phones the header collapses to one
              row and the separate "Admin ▾" pill is hidden, so this menu is the
              only way in. --%>
        <%= if @is_admin do %>
          <div class="card-menu__divider"></div>
          <.link navigate={~p"/games/#{@game}/edit"} class="card-menu__item">✏️ Edit</.link>
          <.link navigate={~p"/games/#{@game}/review"} class="card-menu__item">🔍 Review</.link>
          <.link
            :if={RuleMaven.Games.bgg_synced?(@game)}
            href={~p"/games/#{@game}/prepare"}
            class="card-menu__item"
          >🚀 Prepare</.link>
        <% end %>
      </div>
    </details>
    """
  end
end
