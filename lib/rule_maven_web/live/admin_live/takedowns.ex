defmodule RuleMavenWeb.AdminLive.Takedowns do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Games, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Takedowns", error: nil) |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Allow prefilling the game id (e.g. linked from a game's admin banner).
    {:noreply, assign(socket, prefill_game: params["game"] || "")}
  end

  defp load(socket), do: assign(socket, active: Games.list_taken_down())

  @impl true
  def handle_event("take_down", %{"game_id" => gid, "reason" => reason, "complainant" => who}, socket) do
    reason = String.trim(reason)
    who = String.trim(who)

    cond do
      reason == "" ->
        {:noreply, assign(socket, error: "A reason is required.")}

      true ->
        case Integer.parse(to_string(gid)) do
          {id, _} -> take_down(socket, id, reason, who)
          :error -> {:noreply, assign(socket, error: "Enter a numeric game id.")}
        end
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with {gid, _} <- Integer.parse(to_string(id)),
         game when not is_nil(game) <- Games.get_game(gid),
         {:ok, game} <- Games.restore_game(game) do
      Audit.log(socket.assigns.current_user, "game.restore",
        target_type: "game",
        target_id: game.id,
        target_label: game.name
      )

      {:noreply, socket |> put_flash(:info, "Restored “#{game.name}.”") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't restore that game.")}
    end
  end

  defp take_down(socket, id, reason, who) do
    with game when not is_nil(game) <- Games.get_game(id),
         {:ok, game} <- Games.take_down_game(game, reason, who) do
      Audit.log(socket.assigns.current_user, "game.takedown",
        target_type: "game",
        target_id: game.id,
        target_label: game.name,
        metadata: %{"complainant" => who, "reason" => reason}
      )

      {:noreply,
       socket
       |> assign(error: nil, prefill_game: "")
       |> put_flash(:info, "Took down “#{game.name}.”")
       |> load()}
    else
      nil -> {:noreply, assign(socket, error: "Game not found.")}
      _ -> {:noreply, assign(socket, error: "Couldn't take that game down.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">DMCA Takedowns</h1>
      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem;line-height:1.5">
        Take a game down on a copyright complaint: it's hidden from listings and
        new asks are blocked, with the reason and complainant recorded. Fully
        reversible — restore clears the record. Every takedown and restore is audited.
      </p>

      <form
        phx-submit="take_down"
        style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;margin-bottom:1.5rem;display:grid;grid-template-columns:6rem 1fr;gap:0.6rem 0.75rem;align-items:center"
      >
        <label style={lbl()}>Game ID</label>
        <input type="text" name="game_id" value={@prefill_game} inputmode="numeric" style={inp()} />

        <label style={lbl()}>Complainant</label>
        <input type="text" name="complainant" placeholder="Rights holder / who reported" style={inp()} />

        <label style={lbl()}>Reason</label>
        <textarea name="reason" rows="2" placeholder="Nature of the complaint" style={inp()}></textarea>

        <div></div>
        <div style="display:flex;align-items:center;gap:0.75rem">
          <button
            type="submit"
            style="background:var(--danger,#c0392b);color:#fff;border:none;padding:0.4rem 1rem;border-radius:0.375rem;font-size:0.8rem;font-weight:600;cursor:pointer"
          >Take down</button>
          <span :if={@error} style="font-size:0.75rem;color:var(--red)">{@error}</span>
        </div>
      </form>

      <h2 style="font-size:1.1rem;font-weight:700;margin:0 0 0.5rem">
        Active takedowns
        <span
          :if={@active != []}
          style="margin-left:0.4rem;font-size:0.7rem;font-weight:700;color:#fff;background:var(--danger,#c0392b);border-radius:999px;padding:0.05rem 0.45rem;vertical-align:middle"
        >{length(@active)}</span>
      </h2>

      <%= if @active == [] do %>
        <p style="font-size:0.8rem;color:var(--text-muted)">No games are taken down.</p>
      <% else %>
        <div style="display:flex;flex-direction:column;gap:0.6rem">
          <%= for g <- @active do %>
            <div style="border:1px solid var(--border);border-radius:0.5rem;padding:0.6rem 0.75rem">
              <div style="display:flex;justify-content:space-between;gap:0.5rem;align-items:baseline">
                <span style="font-weight:600;font-size:0.9rem">{g.name} <span style="color:var(--text-muted);font-weight:400">#{g.id}</span></span>
                <button
                  type="button"
                  phx-click="restore"
                  phx-value-id={g.id}
                  data-confirm={"Restore “#{g.name}”? It becomes visible and askable again."}
                  style="background:none;border:1px solid var(--green);color:var(--green);padding:0.15rem 0.6rem;border-radius:0.25rem;font-size:0.72rem;font-weight:600;cursor:pointer"
                >Restore</button>
              </div>
              <p style="font-size:0.78rem;color:var(--text-muted);margin:0.3rem 0 0">{g.takedown_reason}</p>
              <p style="font-size:0.72rem;color:var(--text-muted);margin:0.15rem 0 0">
                Complainant: {g.takedown_complainant || "—"} ·
                {Calendar.strftime(g.taken_down_at, "%b %-d, %Y %H:%M")}
              </p>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp lbl, do: "font-size:0.75rem;font-weight:600;color:var(--text-muted)"

  defp inp,
    do:
      "width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.35rem 0.5rem;font-size:0.8rem;background:var(--bg);color:var(--text);box-sizing:border-box;resize:vertical"
end
