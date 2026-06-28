defmodule RuleMavenWeb.AdminLive.Audit do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket, page_title: "Audit Log", action_filter: "", actions: Audit.actions())
       |> load()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp load(socket) do
    assign(socket, entries: Audit.list(action: socket.assigns.action_filter))
  end

  @impl true
  def handle_event("filter", %{"action" => action}, socket) do
    {:noreply, socket |> assign(action_filter: action) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:64rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Audit Log</h1>
      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem">
        Append-only record of sensitive admin actions (newest first, last 200).
      </p>

      <form phx-change="filter" style="margin-bottom:0.75rem">
        <label style="font-size:0.75rem;color:var(--text-muted);margin-right:0.4rem">Action</label>
        <select
          name="action"
          style="border:1px solid var(--border);border-radius:0.25rem;padding:0.3rem 0.4rem;font-size:0.78rem;background:var(--bg);color:var(--text);cursor:pointer"
        >
          <option value="" selected={@action_filter == ""}>All</option>
          <%= for a <- @actions do %>
            <option value={a} selected={@action_filter == a}>{a}</option>
          <% end %>
        </select>
      </form>

      <%= if @entries == [] do %>
        <p style="font-size:0.8rem;color:var(--text-muted)">No entries.</p>
      <% else %>
        <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
          <table style="width:100%;border-collapse:collapse;font-size:0.78rem">
            <thead>
              <tr style="background:var(--bg-subtle);text-align:left">
                <th style={th()}>When</th>
                <th style={th()}>Actor</th>
                <th style={th()}>Action</th>
                <th style={th()}>Target</th>
                <th style={th()}>Details</th>
              </tr>
            </thead>
            <tbody>
              <%= for e <- @entries do %>
                <tr style="border-top:1px solid var(--border-subtle);vertical-align:top">
                  <td style={td() <> ";white-space:nowrap;color:var(--text-muted)"}>
                    {Calendar.strftime(e.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td style={td()}>{e.actor_username || "—"}</td>
                  <td style={td()}><code style="font-size:0.72rem">{e.action}</code></td>
                  <td style={td()}>
                    <%= if e.target_type do %>
                      <span style="color:var(--text-muted)">{e.target_type}</span>
                      {e.target_label || "##{e.target_id}"}
                    <% else %>
                      —
                    <% end %>
                  </td>
                  <td style={td() <> ";color:var(--text-muted);font-size:0.72rem"}>
                    {format_meta(e.metadata)}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_meta(meta) when meta == %{} or is_nil(meta), do: ""

  defp format_meta(meta) do
    meta
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end

  defp th, do: "padding:0.45rem 0.6rem;font-weight:600;color:var(--text-muted)"
  defp td, do: "padding:0.4rem 0.6rem"
end
