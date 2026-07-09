defmodule RuleMavenWeb.GameLive.SubBar do
  @moduledoc """
  The bar every user-facing game screen wears. `game_bar/1` is the public entry
  point: full-bleed chrome, pinned to the top of the scroll container, wrapping a
  header row of `←` back to the games list, the game name, three group menus
  (🎲 Play · 📚 Learn · 💬 More), and the right-hand pills.

  Always rendered — empty state and mid-conversation alike — so the table tools
  stay one tap away. Mobile-first: at 390px the pills hide and the three short
  menu pills fit one row.

  The pills (Rulebooks, Community Q&A, Cheat Sheet) duplicate More-menu items on
  purpose: they are `hide-mobile` desktop shortcuts, and More is the mobile path
  to the same destinations. Anything reachable from the bar belongs in the More
  menu; not everything in the More menu earns a pill.

  Pages pass `current` — the page they are on. It decides whether Overview
  patches (`:show`) or navigates (everywhere else; patching across LiveViews
  crashes), and swaps the Community pill for a `My Q&A` link back to the game
  page when you are already on Community.
  """
  use RuleMavenWeb, :html
  alias RuleMavenWeb.GameLive.ToolRegistry

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :has_cheatsheet, :boolean, default: false
  attr :current, :atom, default: :show, values: [:show, :community, :prepare, :review, :edit]
  attr :expansions, :list, default: []
  attr :included_expansions, :map, default: %{}
  attr :house_rule_count, :integer, default: 0
  attr :class, :string, default: nil, doc: "extra classes for the chrome element"
  slot :inner_block

  @doc """
  The bar as every game screen wears it: full-bleed chrome, pinned to the top of
  the scroll container, wrapping the header row. Pages render this, not
  `game_header/1` — the chrome is what makes the bar the same control everywhere.

  Render it as a sibling *before* the page's centered content column, so it
  spans the viewport while the content stays centered.
  """
  def game_bar(assigns) do
    ~H"""
    <div class={["game-bar", @class]}>
      <.game_header
        game={@game}
        sources={@sources}
        community_count={@community_count}
        is_admin={@is_admin}
        has_cheatsheet={@has_cheatsheet}
        current={@current}
        expansions={@expansions}
        included_expansions={@included_expansions}
        house_rule_count={@house_rule_count}
      >
        {render_slot(@inner_block)}
      </.game_header>
    </div>
    """
  end

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :has_cheatsheet, :boolean, default: false
  # Which page the bar is being rendered on. Drives two things: the Overview
  # link patches on :show and navigates elsewhere (patching across LiveViews
  # crashes), and the Community pill becomes a `My Q&A` link back to the game
  # page when rendered on Community.
  attr :current, :atom, default: :show, values: [:show, :community, :prepare, :review, :edit]
  attr :expansions, :list, default: []
  attr :included_expansions, :map, default: %{}
  attr :house_rule_count, :integer, default: 0
  slot :inner_block, doc: "page-specific controls, right-aligned (e.g. the Q&A sidebar toggle)"

  @doc """
  The header row itself. An implementation detail of `game_bar/1` — call that
  instead, so the chrome comes with it.
  """
  def game_header(assigns) do
    ~H"""
    <div class="game-header-row">
      <div class="game-header-row__left">
        <.link navigate={~p"/"} class="action-link" style="flex-shrink:0">&larr;</.link>
        <%!-- Same patch-here / navigate-elsewhere split the More menu's
              Overview item uses: patching across LiveViews crashes. --%>
        <.link
          :if={@current == :show}
          patch={~p"/games/#{@game}?start=1"}
          title="Game overview"
          class="chat-header__title"
          style="display:inline-flex;align-items:center;gap:0.25rem;min-width:0;text-decoration:none;color:inherit"
        >
          <h1 class="text-sm font-bold truncate" style="max-width:min(220px,45vw)">
            {@game.name}
          </h1>
        </.link>
        <.link
          :if={@current != :show}
          navigate={~p"/games/#{@game}?start=1"}
          title="Game overview"
          class="chat-header__title"
          style="display:inline-flex;align-items:center;gap:0.25rem;min-width:0;text-decoration:none;color:inherit"
        >
          <h1 class="text-sm font-bold truncate" style="max-width:min(220px,45vw)">
            {@game.name}
          </h1>
        </.link>
        <.sub_bar
          game={@game}
          sources={@sources}
          community_count={@community_count}
          is_admin={@is_admin}
          has_cheatsheet={@has_cheatsheet}
          current={@current}
        />
        <%!-- Meaningless on the admin Edit screen: `included_expansions` there
              is a different concept (the expansion-*link* editor state, not
              "what this user plays with"), and the strip answers "what's at
              my table" — a question Edit has no table for. --%>
        <.table_context
          :if={@current != :edit}
          game={@game}
          expansions={@expansions}
          included_expansions={@included_expansions}
          house_rule_count={@house_rule_count}
        />
      </div>
      <div class="game-header-row__right">
        {render_slot(@inner_block)}
        <.header_pills
          game={@game}
          sources={@sources}
          community_count={@community_count}
          is_admin={@is_admin}
          has_cheatsheet={@has_cheatsheet}
          current={@current}
        />
      </div>
    </div>
    """
  end

  attr :game, :map, required: true
  attr :sources, :list, required: true
  attr :community_count, :integer, required: true
  attr :is_admin, :boolean, required: true
  attr :has_cheatsheet, :boolean, required: true
  attr :current, :atom, required: true

  # The right-hand shortcuts. Every destination here is also a More-menu item —
  # deliberately: these are `hide-mobile` desktop shortcuts and the More menu is
  # the mobile path to the same places. The Community pill points back at the
  # game page when you are on Community, so its slot never empties.
  defp header_pills(assigns) do
    ~H"""
    <details
      :if={@sources != []}
      class="sources-dropdown hide-mobile"
      style="flex-shrink:0;position:relative;display:inline-flex;align-items:center"
    >
      <summary class="pill-link" style="cursor:pointer;list-style:none;gap:0.2rem;user-select:none">
        <span aria-hidden="true">📖</span>
        <span>Rulebooks</span>
        <span style="font-size:0.6rem;opacity:0.6">▾</span>
      </summary>
      <div style="position:absolute;right:0;top:calc(100% + 0.35rem);z-index:200;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;box-shadow:0 6px 20px rgba(0,0,0,0.18);min-width:200px;max-width:min(320px,calc(100vw - 2rem));overflow:hidden">
        <%= for {src, i} <- Enum.with_index(@sources) do %>
          <div style={"padding:0.5rem 0.75rem;#{if i > 0, do: "border-top:1px solid var(--border-subtle)"}"}>
            <div style="font-size:0.78rem;font-weight:600;color:var(--text);margin-bottom:0.25rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">
              {src.label}
            </div>
            <%!-- Rulebooks may be copyrighted, so regular users see only the
                  source name — no PDF, no full text. Admins get the extracted
                  HTML view. `↻ Regen` posts `regenerate_html`, a handler that
                  exists only on the game page, so it is gated to :show. --%>
            <div :if={@is_admin and src.html_path} style="display:flex;gap:0.5rem">
              <.link
                href={~p"/rulebooks/#{src}/html"}
                target="_blank"
                style="display:inline-flex;align-items:center;gap:0.2rem;color:var(--blue);font-size:0.7rem;font-weight:600;text-decoration:none;padding:0.15rem 0.4rem;border:1px solid var(--blue);border-radius:0.25rem;opacity:0.85"
              >🔗 HTML</.link>
              <button
                :if={@current == :show}
                type="button"
                phx-click="regenerate_html"
                phx-value-id={src.id}
                title="Re-render the HTML view from the current text"
                class="btn-xs"
              >↻ Regen</button>
            </div>
          </div>
        <% end %>
      </div>
    </details>

<%!-- On the Community page this pill is the way back to your own Q&A. It
          keeps the slot a Community pill would occupy, so the bar's shape holds. --%>
    <.link
      :if={@current == :community}
      navigate={~p"/games/#{@game}"}
      class="btn btn-primary btn-xs hide-mobile"
      style="flex-shrink:0"
    >
      <span aria-hidden="true">💬</span> My Q&amp;A
    </.link>

    <.link
      :if={@current != :community and @community_count > 0}
      navigate={~p"/games/#{@game}/community"}
      class="btn btn-primary btn-xs hide-mobile"
      style="flex-shrink:0"
    >
      <span aria-hidden="true">💬</span> Community Q&amp;A ({@community_count})
    </.link>

    <%!-- The cheat sheet is a standalone printable document, never "the current
          page", so it is always a plain link. --%>
    <.link
      :if={@has_cheatsheet}
      href={~p"/games/#{@game}/cheatsheet"}
      target="_blank"
      class="btn btn-xs hide-mobile"
      style="flex-shrink:0"
    >
      Cheat Sheet
    </.link>
    """
  end

  attr :game, :map, required: true
  attr :sources, :list, default: []
  attr :community_count, :integer, default: 0
  attr :is_admin, :boolean, default: false
  attr :has_cheatsheet, :boolean, default: false
  attr :current, :atom, default: :show, values: [:show, :community, :prepare, :review, :edit]

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
        has_cheatsheet={@has_cheatsheet}
        current={@current}
      />
    </div>
    """
  end

  attr :game, :map, required: true
  attr :expansions, :list, default: []
  attr :included_expansions, :map, default: %{}
  attr :house_rule_count, :integer, default: 0

  @doc """
  The table-context strip: what this user is actually playing with. Renders at
  all widths, directly under the game title.

  `data-tour="expansions"` lives here — not on the picker — because the picker
  now sits inside a tool panel that is closed by default, and a tour step
  pointed at a hidden element is silently skipped.
  """
  def table_context(assigns) do
    selected = Enum.filter(assigns.expansions, &Map.get(assigns.included_expansions, &1.id))
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <div style="display:flex;align-items:center;gap:0.4rem;flex-wrap:nowrap;min-width:0;flex-shrink:1">
      <button
        :if={@expansions != []}
        type="button"
        data-tour="expansions"
        data-testid="table-context-expansions"
        phx-click="open_tool"
        phx-value-tool="expansions"
        title={expansion_title(@selected)}
        aria-label={expansion_title(@selected)}
        class="pill-link"
        style="display:inline-flex;align-items:center;gap:0.25rem;min-width:0;flex-shrink:1"
      >
        <span aria-hidden="true">📦</span>
        <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0">
          {expansion_label(@selected)}
        </span>
      </button>

      <button
        type="button"
        data-testid="table-context-house-rules"
        phx-click="open_tool"
        phx-value-tool="house_rules"
        class="pill-link"
        style="display:inline-flex;align-items:center;gap:0.25rem;flex-shrink:0"
      >
        <span aria-hidden="true">🏠</span>
        <span>{if @house_rule_count == 0, do: "Add", else: @house_rule_count}</span>
      </button>
    </div>
    """
  end

  defp expansion_label([]), do: "Base game"
  defp expansion_label([one]), do: one.name
  defp expansion_label([first | rest]), do: "#{first.name} +#{length(rest)}"

  defp expansion_title([]), do: "Playing the base game — tap to add expansions"
  defp expansion_title(sel), do: "Playing with: " <> Enum.map_join(sel, ", ", & &1.name)

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
  attr :has_cheatsheet, :boolean, required: true
  attr :current, :atom, required: true

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
      <div class="card-menu__pop card-menu__pop--right card-menu__pop--wide">
        <.link :if={@current == :show} patch={~p"/games/#{@game}?start=1"} class="card-menu__item">
          🔍 Overview
        </.link>
        <.link
          :if={@current != :show}
          navigate={~p"/games/#{@game}?start=1"}
          class="card-menu__item"
        >
          🔍 Overview
        </.link>
        <.link
          :if={@community_count > 0}
          navigate={~p"/games/#{@game}/community"}
          class="card-menu__item"
        >💬 Community Q&amp;A ({@community_count})</.link>
        <%= if @has_cheatsheet do %>
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
