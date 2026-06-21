defmodule RuleMavenWeb.GameLive.Refresh do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, BggRefresher}

  @impl true
  def mount(_params, _session, socket) do
    games =
      if RuleMaven.Users.game_master?(socket.assigns.current_user) do
        Games.list_games()
      else
        Games.list_games_with_documents()
      end
      |> Enum.filter(& &1.bgg_id)
      |> Enum.sort_by(&String.downcase(&1.name))

    total = length(games)
    running = BggRefresher.running?()

    if running do
      BggRefresher.subscribe(self())
    end

    {current, log, complete, error_count} =
      if running do
        case BggRefresher.state() do
          nil -> {0, ["⟳ Reconnecting..."], false, 0}
          s -> {s.current, s.log, s.complete, s.error_count}
        end
      else
        {0, [], false, 0}
      end

    {:ok,
     assign(socket,
       games: games,
       running: running,
       total: total,
       current: current,
       log: log,
       complete: complete,
       error_count: error_count,
       version: 0
     )}
  end

  @impl true
  def handle_info({:progress, name, current, total}, socket) do
    log = ["#{current}/#{total}: #{name}..." | socket.assigns.log]
    ver = socket.assigns.version + 1

    {:noreply, assign(socket, current: current, total: total, log: log, version: ver)}
  end

  @impl true
  def handle_info({:done, name, status}, socket) do
    icon = if status == :ok, do: "✓", else: "✗"

    err =
      if status == :error, do: socket.assigns.error_count + 1, else: socket.assigns.error_count

    log = ["  #{icon} #{name}" | socket.assigns.log]
    ver = socket.assigns.version + 1
    {:noreply, assign(socket, log: log, error_count: err, version: ver)}
  end

  @impl true
  def handle_info({:complete}, socket) do
    {:noreply, assign(socket, complete: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:640px;margin:2rem auto;padding:0 1rem">
      <.link navigate={~p"/"} style="color:var(--blue);font-size:0.8rem">&larr; Back to games</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:1rem 0 0.5rem">Refreshing from BGG</h1>

      <%= if @total == 0 do %>
        <p style="color:var(--text-muted)">No games with BGG IDs to refresh.</p>
      <% else %>
        <%= if !@running do %>
          <div style="text-align:center;padding:2rem;background:var(--bg);border:1px solid var(--border);border-radius:0.75rem">
            <p style="color:var(--text-muted);margin-bottom:0.75rem">No refresh in progress.</p>
            <.link
              navigate={~p"/"}
              style="display:inline-block;background:var(--accent);color:#fff;padding:0.5rem 1.25rem;border-radius:0.5rem;font-size:0.85rem;font-weight:600;text-decoration:none"
            >
              ← Back to Games — click Refresh All
            </.link>
          </div>
        <% else %>
        <div
          style="background:var(--bg);border:1px solid var(--border);border-radius:0.75rem;padding:1.5rem"
          data-refresh={@version}
        >
          <%= if !@complete do %>
            <div style="display:flex;justify-content:space-between;margin-bottom:0.5rem;font-size:0.75rem;color:var(--text-muted)">
              <span>{@current} / {@total}</span>
              <span>{if @total > 0, do: trunc(@current / @total * 100), else: 0}%</span>
            </div>
            <div style="width:100%;height:6px;background:var(--border);border-radius:3px;margin-bottom:1rem;overflow:hidden">
              <div style={"width:#{if @total > 0, do: trunc(@current / @total * 100), else: 0}%;height:100%;background:var(--accent);border-radius:3px;transition:width 0.3s"}>
              </div>
            </div>
            <div style="max-height:32rem;overflow-y:auto;font-size:0.7rem;font-family:monospace;color:var(--text)">
              <%= for entry <- @log do %>
                <div style="padding:0.15rem 0">{entry}</div>
              <% end %>
            </div>
          <% else %>
            <div style="text-align:center;padding:1rem 0">
              <p style="font-size:1.2rem;font-weight:600;color:var(--accent);margin-bottom:0.5rem">
                ✓ Complete
              </p>
              <p style="font-size:0.8rem;color:var(--text-muted);margin-bottom:1rem">
                {@total - @error_count} refreshed, {@error_count} errors
              </p>
              <.link
                navigate={~p"/"}
                style="display:inline-block;background:var(--accent);color:#fff;padding:0.5rem 1.25rem;border-radius:0.5rem;font-size:0.85rem;font-weight:600;text-decoration:none"
              >
                Back to Games
              </.link>
            </div>
          <% end %>
        </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
