defmodule RuleMavenWeb.AdminLive.JobPanel do
  @moduledoc """
  Persistent, admin-only DevTools-style background-job panel. Embedded once via
  `live_render` in the root layout (so it survives live navigation), it docks to
  the bottom of the viewport: a thin collapsed bar showing the running count, and
  an expanded master/detail view — runs on the left, the selected run's event
  stream on the right.

  Rebuilds purely from the durable `job_runs`/`job_events` tables and the live
  `Jobs.admin_topic/0` feed, so it survives a browser refresh and a server
  restart. The open/closed state is persisted client-side in `localStorage` by
  the `JobPanel` JS hook.
  """
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Jobs, Users}

  @max_runs 100
  @max_events 500

  @impl true
  def mount(_params, session, socket) do
    # Independent (root-layout) LiveView — no on_mount hook ran, so resolve the
    # viewer from the session ourselves.
    user =
      case session["user_id"] || session[:user_id] do
        nil -> nil
        id -> Users.get_user(id)
      end

    admin? = Users.can?(user, :admin)

    socket =
      if admin? and connected?(socket) do
        # Close out any runs stranded by a crash/restart before we read, so the
        # rail never shows a ghost "running" job.
        Jobs.reconcile_stale()
        Jobs.subscribe(Jobs.admin_topic())
        socket
      else
        socket
      end

    {:ok,
     assign(socket,
       admin?: admin?,
       open: false,
       runs: (admin? && Jobs.list_runs(limit: @max_runs)) || [],
       # High-volume kinds hidden by default so they don't drown the panel; the
       # admin can toggle them back on via the filter chips.
       hidden_kinds: MapSet.new(["ask"]),
       selected_id: nil,
       events: []
     ), layout: false}
  end

  # Hook restores the persisted open/closed state after connect.
  @impl true
  def handle_event("restore", %{"open" => open}, socket) do
    {:noreply, assign(socket, open: !!open)}
  end

  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, selected_id: id, events: Jobs.events(id, @max_events))}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, selected_id: nil, events: [])}
  end

  def handle_event("toggle-kind", %{"kind" => kind}, socket) do
    hidden = socket.assigns.hidden_kinds

    hidden =
      if MapSet.member?(hidden, kind),
        do: MapSet.delete(hidden, kind),
        else: MapSet.put(hidden, kind)

    {:noreply, assign(socket, hidden_kinds: hidden)}
  end

  # A run opened/closed/changed state — upsert it at the top of the rail.
  @impl true
  def handle_info({:job_run, run}, socket) do
    runs =
      [run | Enum.reject(socket.assigns.runs, &(&1.id == run.id))]
      |> Enum.take(@max_runs)

    {:noreply, assign(socket, runs: runs)}
  end

  # A new progress line — append it to the open run's stream (newest rendered
  # first at render time). Ignore lines for runs we're not viewing.
  def handle_info({:job_event, event}, socket) do
    if event.job_run_id == socket.assigns.selected_id do
      {:noreply, assign(socket, events: Enum.take(socket.assigns.events ++ [event], -@max_events))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(%{admin?: false} = assigns), do: ~H""

  def render(assigns) do
    visible = Enum.reject(assigns.runs, &MapSet.member?(assigns.hidden_kinds, &1.kind))

    assigns =
      assign(assigns,
        visible_runs: visible,
        running_count: Enum.count(visible, &(&1.state == "running")),
        kinds: assigns.runs |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
      )

    ~H"""
    <div id="job-panel" phx-hook="JobPanel" class="jobpanel" data-open={to_string(@open)}>
      <button type="button" class="jobpanel-bar" phx-click="toggle">
        <span class="jobpanel-bar-title">⚙ Background jobs</span>
        <span :if={@running_count > 0} class="jobpanel-badge">{@running_count} running</span>
        <span class="jobpanel-bar-toggle">{if @open, do: "▾", else: "▴"}</span>
      </button>

      <div :if={@open} class="jobpanel-body">
        <div class="jobpanel-list">
          <div :if={@kinds != []} class="jobpanel-filters">
            <button
              :for={kind <- @kinds}
              type="button"
              class={["jobpanel-chip", MapSet.member?(@hidden_kinds, kind) && "is-off"]}
              phx-click="toggle-kind"
              phx-value-kind={kind}
            >
              {kind}
            </button>
          </div>
          <div :if={@visible_runs == []} class="jobpanel-empty">No jobs to show.</div>
          <button
            :for={run <- @visible_runs}
            type="button"
            class={["jobpanel-run", @selected_id == run.id && "is-selected"]}
            phx-click="select"
            phx-value-id={run.id}
          >
            <span class={["jobpanel-dot", "is-#{run.state}"]}></span>
            <span class="jobpanel-run-main">
              <span class="jobpanel-run-label">{run.label || run.kind}</span>
              <span class="jobpanel-run-meta">{run.kind} · {relative_time(run.inserted_at)}</span>
            </span>
            <span class={["jobpanel-state", "is-#{run.state}"]}>{run.state}</span>
          </button>
        </div>

        <div class="jobpanel-detail">
          <%= if @selected_id do %>
            <div class="jobpanel-events">
              <div :if={@events == []} class="jobpanel-empty">No events for this run.</div>
              <div :for={ev <- @events} class="jobpanel-event" style={line_style(ev.level)}>
                <span class="jobpanel-event-time">{Calendar.strftime(ev.inserted_at, "%H:%M:%S")}</span>
                <span class="jobpanel-event-msg">{ev.message}</span>
              </div>
            </div>
          <% else %>
            <div class="jobpanel-empty">Select a job to see its progress.</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Shared line-colour vocabulary with the old ingest/reextract log panels.
  defp line_style("error"), do: "color:var(--red, #c0392b)"
  defp line_style("warn"), do: "color:var(--amber-text, #b8860b)"
  defp line_style("done"), do: "color:var(--green, #2e7d32);font-weight:600"
  defp line_style(_), do: "color:var(--text)"

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
