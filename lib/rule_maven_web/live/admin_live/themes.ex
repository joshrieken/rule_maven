defmodule RuleMavenWeb.AdminLive.Themes do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Metrics, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign_metrics(socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp assign_metrics(socket) do
    counts = Metrics.theme_counts()
    # Every event has exactly one theme, so the total is the sum of the
    # per-theme counts — no second scan of theme_events.
    total = counts |> Map.values() |> Enum.sum()
    max = counts |> Map.values() |> Enum.max(fn -> 0 end)

    # Every theme, count-descending then alphabetical, so zero-use themes still
    # show up at the bottom.
    rows =
      Metrics.themes()
      |> Enum.map(fn {slug, label} -> {slug, label, Map.get(counts, slug, 0)} end)
      |> Enum.sort_by(fn {_slug, label, count} -> {-count, label} end)

    assign(socket, page_title: "Theme Usage", rows: rows, total: total, max: max)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:48rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Admin</.link>
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">Theme Usage</h1>
      <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1.25rem">
        How often each theme has been picked from the switcher. <strong>{@total}</strong>
        selections recorded.
      </p>

      <%= if @total == 0 do %>
        <div class="text-center py-12 text-gray-500">
          <div style="font-size:1.75rem;margin-bottom:0.6rem">🎨</div>
          <p style="font-size:0.9rem">No theme selections recorded yet.</p>
        </div>
      <% else %>
        <div class="space-y-1">
          <%= for {slug, label, count} <- @rows do %>
            <div style="display:flex;align-items:center;gap:0.75rem;padding:0.3rem 0">
              <div style="width:7rem;font-size:0.8rem;font-weight:600;text-align:right;flex-shrink:0">
                {label}
                <span style="font-size:0.62rem;color:var(--text-muted);font-weight:400">{slug}</span>
              </div>
              <div style="flex:1;background:var(--bg-subtle);border-radius:0.3rem;overflow:hidden;height:1.1rem">
                <div style={"height:100%;background:var(--accent);border-radius:0.3rem;width:#{bar_pct(count, @max)}%"}>
                </div>
              </div>
              <div style="width:3rem;font-size:0.8rem;font-weight:700;text-align:right;flex-shrink:0">
                {count}
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp bar_pct(_count, 0), do: 0
  defp bar_pct(count, max), do: round(count / max * 100)
end
