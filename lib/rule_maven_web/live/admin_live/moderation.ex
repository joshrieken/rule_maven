defmodule RuleMavenWeb.AdminLive.Moderation do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Users, Games, Moderation}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Moderation") |> load()}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp load(socket) do
    assign(socket,
      signals: Moderation.user_signals(),
      collusion: Moderation.collusion_pairs()
    )
  end

  # Every action re-checks admin server-side: LiveView events are forgeable over
  # the socket, so the `:admin` live_session on_mount is not the only guard.
  @impl true
  def handle_event(event, params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      do_event(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  defp do_event("suspend_user", %{"id" => id}, socket) do
    with {:ok, user} <- fetch(id),
         :ok <- guard_target(user, socket) do
      {:ok, _} = Users.suspend_user(user)
      audit(socket, "user.suspend", user)

      {:noreply, socket |> put_flash(:info, "Suspended #{user.username}.") |> load()}
    else
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp do_event("unsuspend_user", %{"id" => id}, socket) do
    case fetch(id) do
      {:ok, user} ->
        {:ok, _} = Users.unsuspend_user(user)
        audit(socket, "user.unsuspend", user)
        {:noreply, socket |> put_flash(:info, "Lifted suspension on #{user.username}.") |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp do_event("demote_answers", %{"id" => id}, socket) do
    case fetch(id) do
      {:ok, user} ->
        n = Games.demote_user_answers(user.id)
        audit(socket, "user.demote_answers", user, %{count: n})

        {:noreply,
         socket
         |> put_flash(:info, "Pulled #{n} answer(s) by #{user.username} from the pool.")
         |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp do_event("reset_reputation", %{"id" => id}, socket) do
    case fetch(id) do
      {:ok, user} ->
        {:ok, _} = Users.reset_reputation(user)
        audit(socket, "user.reset_reputation", user)
        {:noreply, socket |> put_flash(:info, "Reset reputation for #{user.username}.") |> load()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int, _} ->
        case Users.get_user(int) do
          nil -> {:error, "User not found."}
          user -> {:ok, user}
        end

      :error ->
        {:error, "Invalid user."}
    end
  end

  defp audit(socket, action, user, metadata \\ %{}) do
    Audit.log(socket.assigns.current_user, action,
      target_type: "user",
      target_id: user.id,
      target_label: user.username,
      metadata: metadata
    )
  end

  # Don't let an admin suspend themselves or another admin (lockout guard).
  defp guard_target(user, socket) do
    cond do
      user.id == socket.assigns.current_user.id -> {:error, "You can't suspend yourself."}
      Users.can?(user, :admin) -> {:error, "You can't suspend another admin. Demote them first."}
      true -> :ok
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:64rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Moderation</h1>
      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem">
        Per-user abuse signals, highest risk first. Blocked = injection attempts; citation-invalid
        = ungrounded answers. New unconfirmed accounts that are already active are flagged.
      </p>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.78rem;white-space:nowrap">
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style={th()}>User</th>
              <th style={th()} title="Total answers authored">Asks</th>
              <th style={th()} title="Injection / blocked questions">Blocked</th>
              <th style={th()}>Refused</th>
              <th style={th()} title="Answers with ungrounded citations">Bad cite</th>
              <th style={th()} title="Owned answers flagged stale">Review</th>
              <th style={th()} title="Answers promoted to the community pool">Pooled</th>
              <th style={th()}>Rep</th>
              <th style={th()} title="Votes cast (up / down)">Votes</th>
              <th style={th()}>Age</th>
              <th style={th()}>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for s <- @signals do %>
              <tr style={"border-top:1px solid var(--border-subtle);#{if s.risk > 0, do: "background:color-mix(in srgb, var(--danger,#c0392b) 6%, transparent)"}"}>
                <td style={td()}>
                  <span style="font-weight:600">{s.username}</span>
                  <span :if={s.is_admin} style={pill("var(--accent)")}>admin</span>
                  <span :if={s.suspended} style={pill("var(--danger,#c0392b)")}>suspended</span>
                  <span
                    :if={not s.confirmed}
                    style={pill("var(--text-muted)")}
                    title="Email not confirmed"
                  >unconfirmed</span>
                </td>
                <td style={td()}>{s.total}</td>
                <td style={num(s.blocked)}>{s.blocked}</td>
                <td style={num(s.refused)}>{s.refused}</td>
                <td style={num(s.citation_invalid)}>{s.citation_invalid}</td>
                <td style={num(s.needs_review)}>{s.needs_review}</td>
                <td style={td()}>{s.community}</td>
                <td style={td()}>{s.reputation}</td>
                <td style={td()}>{s.votes_up}/{s.votes_down}</td>
                <td style={td()}>{if s.age_days, do: "#{s.age_days}d", else: "—"}</td>
                <td style={td()}>
                  <div style="display:flex;gap:0.3rem;flex-wrap:wrap">
                    <%= if s.suspended do %>
                      <button
                        type="button"
                        phx-click="unsuspend_user"
                        phx-value-id={s.user_id}
                        style={btn("var(--green)")}
                      >Unsuspend</button>
                    <% else %>
                      <button
                        :if={not s.is_admin}
                        type="button"
                        phx-click="suspend_user"
                        phx-value-id={s.user_id}
                        data-confirm={"Suspend #{s.username}? They'll be logged out and can't sign in."}
                        style={btn("var(--danger,#c0392b)")}
                      >Suspend</button>
                    <% end %>
                    <button
                      type="button"
                      phx-click="demote_answers"
                      phx-value-id={s.user_id}
                      data-confirm={"Pull all of #{s.username}'s answers from the pool? They become private."}
                      style={btn("var(--text-muted)")}
                    >Pull answers</button>
                    <button
                      type="button"
                      phx-click="reset_reputation"
                      phx-value-id={s.user_id}
                      data-confirm={"Reset #{s.username}'s reputation to 0?"}
                      style={btn("var(--text-muted)")}
                    >Reset rep</button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <h2 style="font-size:1.1rem;font-weight:700;margin:1.75rem 0 0.35rem">Possible vote rings</h2>
      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        Voter→author pairs with repeated votes on the same author. Mostly-up counts are the vote-ring
        signature; reputation effect is already capped, this is for a human call.
      </p>

      <%= if @collusion == [] do %>
        <p style="font-size:0.8rem;color:var(--text-muted)">None above threshold.</p>
      <% else %>
        <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
          <table style="width:100%;border-collapse:collapse;font-size:0.78rem">
            <thead>
              <tr style="background:var(--bg-subtle);text-align:left">
                <th style={th()}>Voter</th>
                <th style={th()}>Author</th>
                <th style={th()}>Votes</th>
                <th style={th()}>Up</th>
              </tr>
            </thead>
            <tbody>
              <%= for p <- @collusion do %>
                <tr style="border-top:1px solid var(--border-subtle)">
                  <td style={td()}>{p.voter_name}</td>
                  <td style={td()}>{p.author_name}</td>
                  <td style={td()}>{p.votes}</td>
                  <td style={td()}>{p.ups}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp th, do: "padding:0.45rem 0.6rem;font-weight:600;color:var(--text-muted)"
  defp td, do: "padding:0.4rem 0.6rem"

  defp num(0), do: td()
  defp num(_), do: td() <> ";font-weight:700;color:var(--danger,#c0392b)"

  defp btn(color),
    do:
      "background:none;border:1px solid #{color};color:#{color};padding:0.15rem 0.5rem;border-radius:0.25rem;font-size:0.7rem;font-weight:600;cursor:pointer"

  defp pill(color),
    do:
      "margin-left:0.35rem;font-size:0.62rem;font-weight:700;color:#{color};border:1px solid #{color};border-radius:999px;padding:0.02rem 0.35rem;vertical-align:middle"
end
