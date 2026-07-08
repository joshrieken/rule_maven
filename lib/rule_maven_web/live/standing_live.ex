defmodule RuleMavenWeb.StandingLive do
  @moduledoc """
  The logged-in user's community standing page, covering both roles:

    * Curator — settlement stats, badges with progress toward the next one,
      and a history of settled votes.
    * Contributor — reputation and promoted/verified counts earned when Q&A
      they asked is validated by the community or an admin.

  Visiting the page consumes any pending settlement notices (advances
  `curator_seen_at`).
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.Games.Curation
  alias RuleMaven.Games.QuestionLog

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket), do: Curation.mark_notices_seen(user)

    {:ok,
     assign(socket,
       page_title: "Community standing",
       stats: Curation.curator_stats(user.id),
       contributor: Curation.contributor_stats(user.id),
       asker: Curation.asker_stats(user.id),
       bonus_cap: Curation.bonus_cap(),
       next_badge: Curation.next_badge(user.id),
       history: Curation.settled_history(user.id)
     )}
  end

  def render(assigns) do
    ~H"""
    <div style="max-width:46rem;margin:0 auto;padding:1.25rem 1rem">
      <h1 style="font-size:1.25rem;font-weight:800;margin:0 0 1.25rem 0">Community standing</h1>

      <h2 style="font-size:1rem;font-weight:700;margin:0 0 0.25rem 0">Curator</h2>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 0.75rem 0">
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
        <h3 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Badges</h3>
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

      <h2 style="font-size:1rem;font-weight:700;margin:0 0 0.25rem 0">Asker</h2>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 0.75rem 0">
        Achievements for asking: every question counts, first-asks (fresh answers
        rather than pool hits) count double-ish, and asking on consecutive days
        keeps a streak alive.
      </p>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:0.75rem;margin-bottom:1.25rem">
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@asker.asked}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">questions asked</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@asker.fresh}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">first-asks (nobody asked before)</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@asker.streak}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">day ask streak</div>
        </div>
      </div>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h3 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Achievements</h3>
        <div style="display:flex;gap:0.5rem;flex-wrap:wrap">
          <span
            :for={a <- @asker.achievements}
            title={if a.earned, do: "Earned!", else: "#{a.have} / #{a.need}"}
            style={"font-size:0.78rem;font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.2rem 0.7rem;background:var(--bg-subtle);#{unless a.earned, do: "opacity:0.45"}"}
          >
            {a.emoji} {a.label}
            <span :if={!a.earned} style="color:var(--text-muted);font-weight:500">
              {a.have}/{a.need}
            </span>
          </span>
        </div>
      </section>

      <h2 style="font-size:1rem;font-weight:700;margin:0 0 0.25rem 0">Contributor</h2>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 0.75rem 0">
        When Q&amp;A you asked is upvoted, promoted to the community pool, or verified
        by a moderator, you earn reputation — and your future votes carry more weight.
      </p>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:0.75rem;margin-bottom:1.25rem">
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@contributor.reputation}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">reputation</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@contributor.promoted}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">answers promoted to community</div>
        </div>
        <div style="border:1px solid var(--border);border-radius:0.75rem;padding:0.9rem 1rem;background:var(--bg-surface)">
          <div style="font-size:1.4rem;font-weight:800">{@contributor.verified}</div>
          <div style="font-size:0.75rem;color:var(--text-muted)">answers verified by moderators</div>
        </div>
      </div>

      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface)">
        <h3 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Settled votes</h3>
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
