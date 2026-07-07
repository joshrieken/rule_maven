defmodule RuleMavenWeb.CuratorLive do
  @moduledoc """
  The logged-in user's curator page: settlement stats, badges with progress
  toward the next one, and a history of settled votes. Visiting the page
  consumes any pending settlement notices (advances `curator_seen_at`).
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.Games.Curation
  alias RuleMaven.Games.QuestionLog

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket), do: Curation.mark_notices_seen(user)

    {:ok,
     assign(socket,
       page_title: "Curator",
       stats: Curation.curator_stats(user.id),
       bonus_cap: Curation.bonus_cap(),
       next_badge: Curation.next_badge(user.id),
       history: Curation.settled_history(user.id)
     )}
  end

  def render(assigns) do
    ~H"""
    <div style="max-width:46rem;margin:0 auto;padding:1.25rem 1rem">
      <h1 style="font-size:1.25rem;font-weight:800;margin:0 0 0.25rem 0">Curator</h1>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 1.25rem 0">
        When an answer you voted on is later confirmed or removed, your vote "settles".
        Correct votes earn curator points and bonus questions.
      </p>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:0.75rem;margin-bottom:1.25rem">
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@stats.points}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">curator points</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">
            {@stats.correct}<span style="font-size:0.85rem;font-weight:600;color:var(--text-muted)"> / {@stats.correct +
              @stats.incorrect}</span>
          </div>
          <div style="font-size:0.75rem;color:var(--text-muted)">votes settled correct</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">
            {@stats.bonus_this_month}<span style="font-size:0.85rem;font-weight:600;color:var(--text-muted)"> / {@bonus_cap}</span>
          </div>
          <div style="font-size:0.75rem;color:var(--text-muted)">bonus questions this month</div>
        </div>
      </div>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Badges</h2>
        <div
          :if={@stats.badges != []}
          style="display:flex;gap:0.5rem;flex-wrap:wrap;margin-bottom:0.75rem"
        >
          <span
            :for={badge <- @stats.badges}
            style="font-size:0.78rem;font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.2rem 0.7rem;background:var(--bg-subtle)"
          >
            🏅 {badge.label}
          </span>
        </div>
        <p
          :if={@stats.badges == []}
          style="font-size:0.8rem;color:var(--text-muted);margin:0 0 0.75rem 0"
        >
          No badges yet — vote on community answers to get started.
        </p>
        <div :if={@next_badge}>
          <div style="display:flex;justify-content:space-between;font-size:0.75rem;color:var(--text-muted);margin-bottom:0.25rem">
            <span>Next: <strong style="color:var(--text)">{@next_badge.label}</strong></span>
            <span>{@next_badge.have} / {@next_badge.need}</span>
          </div>
          <div style="height:0.4rem;border-radius:999px;background:var(--bg-subtle);overflow:hidden">
            <div style={"height:100%;border-radius:999px;background:var(--accent);width:#{min(round(@next_badge.have / @next_badge.need * 100), 100)}%"}>
            </div>
          </div>
        </div>
        <p :if={is_nil(@next_badge)} style="font-size:0.8rem;color:var(--text-muted);margin:0">
          All badges earned. 🎉
        </p>
      </section>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface)">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Settled votes</h2>
        <p :if={@history == []} style="font-size:0.8rem;color:var(--text-muted);margin:0">
          Nothing settled yet. Your votes settle when the community or a moderator
          confirms (or removes) the answer.
        </p>
        <ol style="list-style:none;margin:0;padding:0">
          <li
            :for={entry <- @history}
            style="display:flex;gap:0.6rem;align-items:baseline;padding:0.5rem 0;border-bottom:1px solid var(--border);font-size:0.82rem"
          >
            <span :if={entry.outcome == "correct"} title="Your vote matched the outcome">✅</span>
            <span :if={entry.outcome == "incorrect"} title="Your vote didn't match the outcome">➖</span>
            <span style="flex:1;min-width:0">
              <.link
                navigate={~p"/games/#{entry.game}"}
                style="font-weight:600;text-decoration:none;color:var(--text)"
              >
                {QuestionLog.display_question(entry.question)}
              </.link>
              <span style="color:var(--text-muted)"> — {entry.game.name}</span>
            </span>
            <span style="white-space:nowrap;color:var(--text-muted);font-size:0.72rem">
              {if entry.value == "up", do: "👍", else: "👎"}
              {Calendar.strftime(entry.settled_at, "%b %d")}
            </span>
          </li>
        </ol>
      </section>
    </div>
    """
  end
end
