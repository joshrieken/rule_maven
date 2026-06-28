defmodule RuleMavenWeb.AdminLive.Usage do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, LLM, Settings, Audit}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket,
         page_title: "Usage & Cost",
         days: 30,
         cost_cap: Settings.get("user_daily_cost_cap") || "0"
       )
       |> load()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp load(socket) do
    days = socket.assigns.days
    by_user = LLM.cost_by_user(days)

    assign(socket,
      stats: LLM.stats(days),
      by_user: by_user,
      total_cost: Enum.reduce(by_user, 0.0, &(&1.cost + &2))
    )
  end

  @impl true
  def handle_event("set_days", %{"days" => days}, socket) do
    {:noreply, socket |> assign(days: String.to_integer(days)) |> load()}
  end

  def handle_event("save_cap", %{"cap" => cap}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      cap = String.trim(cap)
      Settings.put("user_daily_cost_cap", cap)
      Audit.log(socket.assigns.current_user, "settings.cost_cap", metadata: %{cap: cap})

      {:noreply,
       socket
       |> assign(cost_cap: cap)
       |> put_flash(:info, "Daily budget cap saved.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:60rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;margin:0.25rem 0 1rem">
        <h1 style="font-size:1.5rem;font-weight:700">Usage &amp; Cost</h1>
        <form phx-change="set_days">
          <select
            name="days"
            style="border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.4rem;font-size:0.78rem;background:var(--bg);color:var(--text);cursor:pointer"
          >
            <option :for={d <- [7, 30, 90]} value={d} selected={@days == d}>Last {d} days</option>
          </select>
        </form>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(9rem,1fr));gap:0.6rem;margin-bottom:1.25rem">
        <.stat label="Est. cost" value={"$#{fmt_cost(@total_cost)}"} />
        <.stat label="Requests" value={@stats.total_requests} />
        <.stat label="Tokens" value={fmt_int(@stats.total_tokens)} />
        <.stat label="Errors" value={@stats.error_count} />
        <.stat label="Avg latency" value={"#{@stats.avg_duration_ms || 0} ms"} />
      </div>

      <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem 1rem;margin-bottom:1.25rem">
        <form phx-submit="save_cap" style="display:flex;align-items:end;gap:0.6rem;flex-wrap:wrap">
          <div>
            <label style="display:block;font-size:0.72rem;font-weight:600;color:var(--text-muted);margin-bottom:0.2rem">
              Per-user daily budget cap (USD, 0 = off)
            </label>
            <input
              type="text"
              name="cap"
              value={@cost_cap}
              inputmode="decimal"
              style="width:8rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
            />
          </div>
          <button
            type="submit"
            style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.78rem;font-weight:600;cursor:pointer"
          >Save</button>
          <span style="font-size:0.72rem;color:var(--text-muted)">
            Blocks a user's new asks once their estimated spend today hits the cap. Admins exempt.
          </span>
        </form>
      </div>

      <h2 style="font-size:1.1rem;font-weight:700;margin:0 0 0.5rem">Cost by user</h2>
      <p style="font-size:0.72rem;color:var(--text-muted);margin:0 0 0.6rem">
        Estimated from logged token usage; for budgeting, not billing.
      </p>

      <%= if @by_user == [] do %>
        <p style="font-size:0.8rem;color:var(--text-muted)">No usage in this window.</p>
      <% else %>
        <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
          <table style="width:100%;border-collapse:collapse;font-size:0.8rem">
            <thead>
              <tr style="background:var(--bg-subtle);text-align:left">
                <th style={th()}>User</th>
                <th style={th()}>Est. cost</th>
                <th style={th()}>Requests</th>
                <th style={th()}>Tokens</th>
              </tr>
            </thead>
            <tbody>
              <%= for u <- @by_user do %>
                <tr style="border-top:1px solid var(--border-subtle)">
                  <td style={td()}>{u.username}</td>
                  <td style={td() <> ";font-weight:600"}>${fmt_cost(u.cost)}</td>
                  <td style={td()}>{u.requests}</td>
                  <td style={td()}>{fmt_int(u.tokens)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem">
      <div style="font-size:0.65rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);font-weight:700">
        {@label}
      </div>
      <div style="font-size:1.15rem;font-weight:700;color:var(--text);margin-top:0.15rem">
        {@value}
      </div>
    </div>
    """
  end

  defp fmt_cost(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp fmt_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp fmt_int(_), do: "0"

  defp th, do: "padding:0.45rem 0.6rem;font-weight:600;color:var(--text-muted)"
  defp td, do: "padding:0.4rem 0.6rem"
end
