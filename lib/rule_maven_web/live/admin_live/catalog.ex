defmodule RuleMavenWeb.AdminLive.Catalog do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{BGG, Games, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.game_master?(socket.assigns.current_user) do
      {:ok,
       assign(socket,
         page_title: "Game Catalog",
         bgg_user: "",
         bgg_pass: "",
         importing: false,
         error: nil,
         result: nil,
         total_games: Games.count_games()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("import", params, socket) do
    bgg_user = String.trim(params["bgg_user"] || "")
    bgg_pass = params["bgg_pass"] || ""

    if bgg_user == "" or bgg_pass == "" do
      {:noreply, assign(socket, error: "BGG username and password are both required.")}
    else
      socket =
        assign(socket, importing: true, error: nil, result: nil, bgg_user: bgg_user)

      send(self(), {:run_import, bgg_user, bgg_pass})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:run_import, bgg_user, bgg_pass}, socket) do
    result =
      with {:ok, cookies} <- BGG.login(bgg_user, bgg_pass),
           {:ok, csv} <- BGG.fetch_rank_dump(cookies) do
        count = Games.import_rank_dump(csv)
        {:ok, count}
      end

    case result do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(
           importing: false,
           result: count,
           bgg_pass: "",
           total_games: Games.count_games()
         )
         |> put_flash(:info, "Imported/updated #{count} games from the BGG catalog.")}

      {:error, reason} ->
        {:noreply, assign(socket, importing: false, bgg_pass: "", error: to_string(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Game Catalog</h1>

      <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 1rem;line-height:1.5">
        Bulk-import the full BoardGameGeek catalog from their official daily data dump
        (~150k games). Provide BGG credentials — the dump download is login-gated.
        Credentials are used only for this request and never stored. Runs an idempotent
        upsert by BGG id, so it is safe to re-run; existing enriched data (images,
        player counts) is preserved.
      </p>

      <p style="font-size:0.78rem;color:var(--text-secondary);margin:0 0 1rem">
        Catalog currently holds <strong>{@total_games}</strong> games.
      </p>

      <form phx-submit="import" style="border:1px solid var(--border);border-radius:0.5rem;padding:1rem;background:var(--bg-surface)">
        <div style="display:flex;flex-direction:column;gap:0.6rem">
          <div>
            <label style="display:block;font-size:0.75rem;font-weight:600;margin-bottom:0.2rem">BGG Username</label>
            <input
              type="text"
              name="bgg_user"
              value={@bgg_user}
              autocomplete="off"
              disabled={@importing}
              style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
            />
          </div>
          <div>
            <label style="display:block;font-size:0.75rem;font-weight:600;margin-bottom:0.2rem">BGG Password</label>
            <input
              type="password"
              name="bgg_pass"
              value={@bgg_pass}
              autocomplete="off"
              disabled={@importing}
              style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
            />
          </div>
          <button
            type="submit"
            disabled={@importing}
            style={"background:var(--accent);color:#fff;border:none;padding:0.5rem 1rem;border-radius:0.375rem;font-weight:600;font-size:0.85rem;cursor:#{if @importing, do: "default", else: "pointer"};opacity:#{if @importing, do: "0.6", else: "1"}"}
          >
            {if @importing, do: "Importing… (this can take a minute)", else: "Import Full Catalog"}
          </button>
        </div>
      </form>

      <%= if @importing do %>
        <div style="margin-top:1rem;padding:0.75rem;background:var(--bg-subtle);border-radius:0.5rem;font-size:0.8rem;color:var(--text-muted)" class="animate-pulse">
          Logging in, downloading the data dump, and upserting the catalog…
        </div>
      <% end %>

      <%= if @error do %>
        <div style="margin-top:1rem;padding:0.75rem;background:color-mix(in srgb,var(--red) 10%,transparent);border:1px solid var(--red);border-radius:0.5rem;font-size:0.8rem;color:var(--red)">
          {@error}
        </div>
      <% end %>

      <%= if @result do %>
        <div style="margin-top:1rem;padding:0.75rem;background:color-mix(in srgb,var(--green) 10%,transparent);border:1px solid var(--green);border-radius:0.5rem;font-size:0.8rem;color:var(--green)">
          Done — {@result} games imported/updated.
        </div>
      <% end %>
    </div>
    """
  end
end
