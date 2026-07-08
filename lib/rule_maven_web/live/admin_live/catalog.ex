defmodule RuleMavenWeb.AdminLive.Catalog do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, BGG, Games, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket,
         page_title: "Game Catalog",
         importing: false,
         error: nil,
         result: nil,
         confirm_clear: false,
         confirm_text: "",
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
  def handle_event("import", _params, socket) do
    user = RuleMaven.Settings.get("bgg_user")
    pass = RuleMaven.Settings.get("bgg_pass")

    if blank?(user) or blank?(pass) do
      {:noreply,
       assign(socket,
         error: "Set the app's BGG username and password in Settings before importing."
       )}
    else
      # Run login + multi-MB dump download + upsert off the LiveView process so
      # the page stays responsive; result comes back via handle_async.
      socket =
        start_async(socket, :import_catalog, fn ->
          # The data-dump page is login-gated and the BGG API token does not
          # unlock it, so authenticate with the app's stored BGG account first.
          with {:ok, cookies} <- BGG.login(user, pass),
               {:ok, csv} <- BGG.fetch_rank_dump(cookies) do
            {:ok, Games.import_rank_dump(csv)}
          end
        end)

      {:noreply, assign(socket, importing: true, error: nil, result: nil)}
    end
  end

  @impl true
  def handle_event("confirm_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: true)}
  end

  @impl true
  def handle_event("confirm_cancel", _params, socket) do
    {:noreply, assign(socket, confirm_clear: false, confirm_text: "")}
  end

  @impl true
  def handle_event("confirm_input", params, socket) do
    text = params["value"] || params["confirm_text"] || ""
    {:noreply, assign(socket, confirm_text: text)}
  end

  @impl true
  def handle_event("clear_all_games", _params, socket) do
    {count, _} = Games.delete_all_games()

    Audit.log(socket.assigns.current_user, "catalog.clear_all", metadata: %{"deleted" => count})

    {:noreply,
     socket
     |> assign(confirm_clear: false, confirm_text: "", total_games: Games.count_games())
     |> put_flash(:info, "Cleared #{count} game(s).")}
  end

  @impl true
  def handle_async(:import_catalog, {:ok, {:ok, count}}, socket) do
    Audit.log(socket.assigns.current_user, "catalog.import", metadata: %{"imported" => count})

    {:noreply,
     socket
     |> assign(importing: false, result: count, total_games: Games.count_games())
     |> put_flash(:info, "Imported/updated #{count} games from the BGG catalog.")}
  end

  def handle_async(:import_catalog, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, importing: false, error: to_string(reason))}
  end

  def handle_async(:import_catalog, {:exit, reason}, socket) do
    {:noreply, assign(socket, importing: false, error: "Import crashed: #{inspect(reason)}")}
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Game Catalog</h1>

      <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 1rem;line-height:1.5">
        Bulk-import the full BoardGameGeek catalog from their official daily data dump
        (~150k games). The dump download is login-gated, so it authenticates with the
        app's BGG username and password configured in Settings — nothing is entered
        here. Runs an idempotent upsert by BGG id, so it is safe to re-run; existing
        enriched data (images, player counts) is preserved.
      </p>

      <p style="font-size:0.78rem;color:var(--text-secondary);margin:0 0 1rem">
        Catalog currently holds <strong>{@total_games}</strong> games.
      </p>

      <form
        phx-submit="import"
        style="border:1px solid var(--border);border-radius:0.5rem;padding:1rem;background:var(--bg-surface)"
      >
        <div style="display:flex;flex-direction:column;gap:0.6rem">
          <button
            type="submit"
            disabled={@importing}
            class="btn-primary"
            style={"cursor:#{if @importing, do: "default", else: "pointer"};opacity:#{if @importing, do: "0.6", else: "1"}"}
          >
            {if @importing, do: "Importing… (this can take a minute)", else: "Import Full Catalog"}
          </button>
        </div>
      </form>

      <%= if @importing do %>
        <div
          style="margin-top:1rem;padding:0.75rem;background:var(--bg-subtle);border-radius:0.5rem;font-size:0.8rem;color:var(--text-muted)"
          class="animate-pulse"
        >
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

      <%!-- Danger Zone --%>
      <div
        :if={@total_games > 0}
        style="margin-top:2rem;border:1px solid var(--red);border-radius:0.5rem;padding:0.75rem 0.9rem;background:var(--bg)"
      >
        <h3 style="font-size:0.78rem;font-weight:700;color:var(--red);margin:0 0 0.5rem 0;text-transform:uppercase;letter-spacing:0.03em">
          Danger Zone
        </h3>
        <div class="flex gap-2 flex-wrap" style="align-items:center">
          <%= if not @confirm_clear do %>
            <button
              type="button"
              phx-click="confirm_clear"
              class="btn-danger btn-sm"
            >
              Clear All Games
            </button>
          <% else %>
            <form phx-change="confirm_input" style="display:inline">
              <span class="text-sm font-medium" style="color:var(--red)">Type DELETE to confirm:</span>
              <input
                type="text"
                name="confirm_text"
                value={@confirm_text}
                placeholder="DELETE"
                style="border:1px solid var(--red);border-radius:0.375rem;padding:0.25rem 0.5rem;font-size:0.8rem;width:6rem"
              />
            </form>
            <button
              type="button"
              phx-click="clear_all_games"
              disabled={@confirm_text != "DELETE"}
              class="btn-danger btn-sm"
            >
              Delete All
            </button>
            <button
              type="button"
              phx-click="confirm_cancel"
              class="btn-sm"
            >
              Cancel
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
