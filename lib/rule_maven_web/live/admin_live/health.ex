defmodule RuleMavenWeb.AdminLive.Health do
  use RuleMavenWeb, :live_view

  import Ecto.Query

  alias RuleMaven.{Audit, LLM, Repo, Settings, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      if connected?(socket), do: :timer.send_interval(15_000, self(), :refresh)

      {:ok,
       socket
       |> assign(
         page_title: "System Health",
         cost_alert: Settings.get("global_daily_cost_alert") || "0",
         super_admin?: Users.can?(socket.assigns.current_user, :superadmin)
       )
       |> load()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("save_alert", %{"alert" => alert}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      alert = String.trim(alert)
      Settings.put("global_daily_cost_alert", alert)
      Audit.log(socket.assigns.current_user, "settings.cost_alert", metadata: %{threshold: alert})

      {:noreply,
       socket
       |> assign(cost_alert: alert)
       |> put_flash(:info, "Daily cost alert saved.")
       |> load()}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  defp load(socket) do
    assign(socket,
      oban: oban_counts(),
      err: LLM.error_rate(24),
      cost_today: LLM.cost_today(),
      total_users: Repo.aggregate(Users.User, :count),
      updated_at: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
    )
  end

  # Oban job counts by state (overall) and per-queue for the "live" states.
  defp oban_counts do
    by_state =
      Repo.all(from j in "oban_jobs", group_by: j.state, select: {j.state, count(j.id)})
      |> Map.new()

    per_queue =
      Repo.all(
        from j in "oban_jobs",
          where: j.state in ["available", "executing", "retryable", "scheduled"],
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
      )
      |> Enum.group_by(fn {q, _, _} -> q end, fn {_, s, c} -> {s, c} end)
      |> Enum.map(fn {q, states} -> {q, Map.new(states)} end)
      |> Enum.sort_by(fn {q, _} -> q end)

    %{by_state: by_state, per_queue: per_queue}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:56rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:1rem;margin:0.25rem 0 1rem">
        <h1 style="font-size:1.5rem;font-weight:700">System Health</h1>
        <span style="font-size:0.7rem;color:var(--text-muted)">Auto-refresh · {@updated_at}</span>
      </div>

      <%!-- Cost alert banner --%>
      <% threshold = parse_num(@cost_alert) %>
      <div
        :if={threshold > 0 and @cost_today >= threshold}
        style="border:1px solid var(--danger,#c0392b);background:color-mix(in srgb,var(--danger,#c0392b) 10%,transparent);color:var(--danger,#c0392b);border-radius:0.5rem;padding:0.6rem 0.9rem;margin-bottom:1rem;font-size:0.82rem;font-weight:600"
      >
        ⚠️ Today's LLM spend (${fmt(@cost_today)}) has reached the alert threshold (${fmt(threshold)}).
      </div>

      <%!-- Top stats --%>
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(9rem,1fr));gap:0.6rem;margin-bottom:1.25rem">
        <.stat
          label="Spend today"
          value={"$#{fmt(@cost_today)}"}
          danger={threshold > 0 and @cost_today >= threshold}
        />
        <.stat label="LLM errors (24h)" value={@err.errors} danger={@err.errors > 0} />
        <.stat
          label="Error rate (24h)"
          value={"#{Float.round(@err.rate * 100, 1)}%"}
          danger={@err.rate > 0.1}
        />
        <.stat label="Requests (24h)" value={@err.requests} />
        <.stat label="Users" value={@total_users} />
      </div>

      <%!-- Oban --%>
      <h2 style="font-size:1.1rem;font-weight:700;margin:0 0 0.5rem">Background jobs (Oban)</h2>
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(8rem,1fr));gap:0.6rem;margin-bottom:1rem">
        <.stat label="Executing" value={state(@oban, "executing")} />
        <.stat
          label="Available"
          value={state(@oban, "available")}
          danger={state(@oban, "available") > 100}
        />
        <.stat
          label="Retryable"
          value={state(@oban, "retryable")}
          danger={state(@oban, "retryable") > 0}
        />
        <.stat label="Scheduled" value={state(@oban, "scheduled")} />
        <.stat
          label="Discarded"
          value={state(@oban, "discarded")}
          danger={state(@oban, "discarded") > 0}
        />
      </div>

      <%= if @oban.per_queue != [] do %>
        <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem;margin-bottom:0.5rem">
          <table style="width:100%;border-collapse:collapse;font-size:0.78rem">
            <thead>
              <tr style="background:var(--bg-subtle);text-align:left">
                <th style={th()}>Queue</th>
                <th style={th()}>Executing</th>
                <th style={th()}>Available</th>
                <th style={th()}>Retryable</th>
                <th style={th()}>Scheduled</th>
              </tr>
            </thead>
            <tbody>
              <%= for {queue, states} <- @oban.per_queue do %>
                <tr style="border-top:1px solid var(--border-subtle)">
                  <td style={td()}><code>{queue}</code></td>
                  <td style={td()}>{Map.get(states, "executing", 0)}</td>
                  <td style={td()}>{Map.get(states, "available", 0)}</td>
                  <td style={num(Map.get(states, "retryable", 0))}>
                    {Map.get(states, "retryable", 0)}
                  </td>
                  <td style={td()}>{Map.get(states, "scheduled", 0)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
      <p :if={@super_admin?} style="font-size:0.72rem;color:var(--text-muted);margin:0 0 1.5rem">
        Deep job inspection lives in the <.link
          href="/oban"
          target="_blank"
          style="color:var(--accent-ink, var(--accent))"
        >Oban dashboard ↗</.link>.
      </p>

      <%!-- Cost alert setting --%>
      <h2 style="font-size:1.1rem;font-weight:700;margin:0 0 0.5rem">Daily cost alert</h2>
      <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:0.75rem 1rem">
        <form phx-submit="save_alert" style="display:flex;align-items:end;gap:0.6rem;flex-wrap:wrap">
          <div>
            <label style="display:block;font-size:0.72rem;font-weight:600;color:var(--text-muted);margin-bottom:0.2rem">
              Whole-app daily spend alert (USD, 0 = off)
            </label>
            <input
              type="text"
              name="alert"
              value={@cost_alert}
              inputmode="decimal"
              style="width:8rem;border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
            />
          </div>
          <button
            type="submit"
            class="btn-primary btn-sm"
          >Save</button>
          <span style="font-size:0.72rem;color:var(--text-muted)">
            Shows a banner here once today's total estimated spend crosses this. Per-user caps live on Usage &amp; Cost.
          </span>
        </form>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :danger, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div style={"background:var(--bg-surface);border:1px solid #{if @danger, do: "var(--danger,#c0392b)", else: "var(--border)"};border-radius:0.5rem;padding:0.6rem 0.75rem"}>
      <div style="font-size:0.68rem;color:var(--text-muted);font-weight:600;text-transform:uppercase;letter-spacing:0.03em">
        {@label}
      </div>
      <div style={"font-size:1.25rem;font-weight:700;#{if @danger, do: "color:var(--danger,#c0392b)"}"}>
        {@value}
      </div>
    </div>
    """
  end

  defp state(oban, s), do: Map.get(oban.by_state, s, 0)

  defp parse_num(v) do
    case Float.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp fmt(_), do: "0.00"

  defp th, do: "padding:0.45rem 0.6rem;font-weight:600;color:var(--text-muted)"
  defp td, do: "padding:0.4rem 0.6rem"
  defp num(0), do: td()
  defp num(_), do: td() <> ";font-weight:700;color:var(--danger,#c0392b)"
end
