defmodule RuleMavenWeb.AdminLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, Games, Settings, Audit}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket,
         page_title: "Admin",
         review_backlog: Games.needs_review_count(),
         flag_backlog: Games.count_pending_flags(),
         asks_disabled: Settings.asks_disabled?()
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle_asks", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      disable? = not socket.assigns.asks_disabled
      Settings.set_asks_disabled(disable?)

      Audit.log(
        socket.assigns.current_user,
        if(disable?, do: "asks.disable", else: "asks.enable")
      )

      {:noreply,
       socket
       |> assign(asks_disabled: disable?)
       |> put_flash(:info, if(disable?, do: "Asks paused.", else: "Asks resumed."))}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/"} class="back-link">&larr; Back to games</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 1rem">Admin Dashboard</h1>

      <div style={"display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:0.75rem 1rem;margin-bottom:1rem;border-radius:0.5rem;border:1px solid #{if @asks_disabled, do: "var(--danger,#c0392b)", else: "var(--border)"};background:var(--bg-surface)"}>
        <div>
          <div style="font-weight:700;font-size:0.85rem;color:var(--text)">
            {if @asks_disabled, do: "⏸️ Asks are paused", else: "▶️ Asks are live"}
          </div>
          <div style="font-size:0.75rem;color:var(--text-muted)">
            Kill switch for new LLM answers. Existing answers keep serving; admins can still ask.
          </div>
        </div>
        <button
          type="button"
          phx-click="toggle_asks"
          data-confirm={
            if !@asks_disabled, do: "Pause all new question answering for users?", else: false
          }
          style={"flex-shrink:0;border:1px solid #{if @asks_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};color:#{if @asks_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};background:none;padding:0.35rem 0.9rem;border-radius:0.375rem;font-size:0.78rem;font-weight:700;cursor:pointer"}
        >
          {if @asks_disabled, do: "Resume asks", else: "Pause asks"}
        </button>
      </div>

      <.section title="Review">
        <.card
          navigate={
            if @review_backlog > 0,
              do: ~p"/admin/questions?status=needs_review",
              else: ~p"/admin/questions"
          }
          icon="💬"
          title="Questions"
          desc="Browse, filter, and delete user questions."
          badge={@review_backlog > 0 && "#{@review_backlog} to review"}
          badge_title="Community answers flagged stale by a rulebook change, awaiting re-approval"
        />
        <.card
          navigate={~p"/admin/moderation"}
          icon="🚩"
          title="Moderation"
          desc="Per-user abuse signals, vote rings, suspend/pull-answers."
          badge={@flag_backlog > 0 && "#{@flag_backlog} reported"}
          badge_title="Answers users reported as wrong or unhelpful, awaiting review"
        />
        <.card
          navigate={~p"/admin/audit"}
          icon="📜"
          title="Audit Log"
          desc="Append-only record of sensitive admin actions."
        />
        <.card
          navigate={~p"/admin/threads"}
          icon="🧵"
          title="Review Threads"
          desc="Review Q&A threads with followups. Merge into FAQ entries."
        />
      </.section>

      <.section title="Manage">
        <.card
          navigate={~p"/admin/users"}
          icon="👥"
          title="Manage Users"
          desc="Promote players to admins. Manage roles."
        />
        <.card
          navigate={~p"/admin/invites"}
          icon="🎟️"
          title="Invite Codes"
          desc="Generate invite codes for new user registration."
        />
        <.card
          navigate={~p"/admin/catalog"}
          icon="📦"
          title="Game Catalog"
          desc="Bulk-import the full BoardGameGeek catalog (~150k games)."
        />
        <.card
          navigate={~p"/admin/requests"}
          icon="🙋"
          title="Support Requests"
          desc="Games users want supported, ranked by demand."
        />
      </.section>

      <.section title="System">
        <.card
          navigate={~p"/admin/security"}
          icon="🛡️"
          title="Security"
          desc="Blocked questions and injection pattern management."
        />
        <.card
          navigate={~p"/admin/usage"}
          icon="📊"
          title="Usage & Cost"
          desc="LLM token spend per user, with a daily budget cap."
        />
        <.card
          navigate={~p"/admin/db"}
          icon="🗄️"
          title="DB Admin"
          desc="Browse, edit, and manage database tables directly."
        />
        <.card
          navigate={~p"/admin/themes"}
          icon="🎨"
          title="Theme Usage"
          desc="Which themes users have selected."
        />
        <.card
          navigate={~p"/settings"}
          icon="🔧"
          title="Settings"
          desc="LLM provider, model, API keys, rate limits."
        />
        <.card
          href="/oban"
          target="_blank"
          icon="⚙️"
          title="Oban Dashboard ↗"
          desc="Background job queue and processing dashboard."
        />
      </.section>
    </div>
    """
  end

  slot :inner_block, required: true
  attr :title, :string, required: true

  defp section(assigns) do
    ~H"""
    <h2 style="font-size:0.7rem;font-weight:700;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);margin:1.25rem 0 0.5rem">
      {@title}
    </h2>
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(14rem,1fr));gap:0.75rem">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :target, :string, default: nil
  attr :badge, :any, default: nil
  attr :badge_title, :string, default: nil

  defp card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      href={@href}
      target={@target}
      style="position:relative;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
    >
      <span
        :if={@badge}
        title={@badge_title}
        style="position:absolute;top:0.6rem;right:0.6rem;background:var(--danger,#c0392b);color:#fff;font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.45rem"
      >
        {@badge}
      </span>
      <div style="font-size:1.5rem;margin-bottom:0.4rem">{@icon}</div>
      <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
        {@title}
      </div>
      <div style="font-size:0.8rem;color:var(--text-muted)">{@desc}</div>
    </.link>
    """
  end
end
