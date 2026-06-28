defmodule RuleMavenWeb.AdminLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, Games}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Admin", review_backlog: Games.needs_review_count())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/"} class="back-link">&larr; Back to games</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 1rem">Admin Dashboard</h1>

      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(14rem,1fr));gap:0.75rem">
        <.link
          navigate={~p"/admin/security"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🛡️</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Security
          </div>
          <div style="font-size:0.8rem;color:var(--text-muted)">
            Blocked questions and injection pattern management.
          </div>
        </.link>

        <.link
          navigate={
            if @review_backlog > 0,
              do: ~p"/admin/questions?status=needs_review",
              else: ~p"/admin/questions"
          }
          style="position:relative;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <span
            :if={@review_backlog > 0}
            title="Community answers flagged stale by a rulebook change, awaiting re-approval"
            style="position:absolute;top:0.6rem;right:0.6rem;background:var(--danger,#c0392b);color:#fff;font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.45rem"
          >
            {@review_backlog} to review
          </span>
          <div style="font-size:1.5rem;margin-bottom:0.4rem">💬</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Questions
          </div>
          <div style="font-size:0.8rem;color:var(--text-muted)">
            Browse, filter, and delete user questions.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/moderation"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🚩</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Moderation
          </div>
          <div style="font-size:0.8rem;color:var(--text-muted)">
            Per-user abuse signals, vote rings, suspend/pull-answers.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/audit"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">📜</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Audit Log
          </div>
          <div style="font-size:0.8rem;color:var(--text-muted)">
            Append-only record of sensitive admin actions.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/db"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🗄️</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            DB Admin
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Browse, edit, and manage database tables directly.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/threads"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">💬</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Review Threads
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Review Q&A threads with followups. Merge into FAQ entries.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/catalog"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">📦</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Game Catalog
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Bulk-import the full BoardGameGeek catalog (~150k games).
          </div>
        </.link>

        <.link
          navigate={~p"/admin/requests"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🙋</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Support Requests
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Games users want supported, ranked by demand.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/users"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">👥</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Manage Users
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Promote players to game masters. Manage roles.
          </div>
        </.link>

        <.link
          navigate={~p"/admin/invites"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🎟️</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Invite Codes
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Generate invite codes for new user registration.
          </div>
        </.link>

        <.link
          href="/oban"
          target="_blank"
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">⚙️</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Oban Dashboard ↗
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            Background job queue and processing dashboard.
          </div>
        </.link>

        <.link
          navigate={~p"/settings"}
          style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
        >
          <div style="font-size:1.5rem;margin-bottom:0.4rem">🔧</div>
          <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
            Settings
          </div>
          <div style="font-size:0.72rem;color:var(--text-muted)">
            LLM provider, model, API keys, rate limits.
          </div>
        </.link>
      </div>
    </div>
    """
  end
end
