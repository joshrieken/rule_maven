defmodule RuleMavenWeb.AdminLive.Requests do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket, page_title: "Support Requests", requests: Games.list_support_requests())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:48rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Admin</.link>
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">Support Requests</h1>
      <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1.25rem">
        Games users have in their collection but aren't yet ready, ranked by demand.
      </p>

      <%= if @requests == [] do %>
        <div class="text-center py-12 text-gray-500">
          <div style="font-size:1.75rem;margin-bottom:0.6rem">📭</div>
          <p style="font-size:0.9rem">No support requests yet.</p>
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for r <- @requests do %>
            <div style="display:flex;align-items:center;gap:0.75rem;border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem 1rem;background:var(--bg-surface)">
              <span style="background:var(--accent);color:var(--accent-text,#fff);font-size:0.8rem;font-weight:700;min-width:2rem;text-align:center;padding:0.15rem 0.4rem;border-radius:0.35rem">
                {r.count}
              </span>
              <div class="flex-1 min-w-0">
                <div style="font-weight:600;font-size:0.9rem">{r.game.name}</div>
                <div style="font-size:0.72rem;color:var(--text-muted)">
                  last requested {Calendar.strftime(r.last_requested_at, "%Y-%m-%d")}
                </div>
              </div>
              <.link
                :if={r.game.bgg_id}
                href={"https://boardgamegeek.com/boardgame/#{r.game.bgg_id}"}
                target="_blank"
                rel="noopener"
                style="background:var(--bg-subtle);color:#ea580c;text-decoration:none;font-size:0.72rem;font-weight:600;padding:0.2rem 0.5rem;border-radius:0.3rem;border:1px solid var(--border)"
              >BGG</.link>
              <.link
                navigate={~p"/games/#{r.game}/edit"}
                style="background:var(--accent);color:var(--accent-text,#fff);text-decoration:none;font-size:0.72rem;font-weight:600;padding:0.2rem 0.55rem;border-radius:0.3rem"
              >Add support</.link>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
