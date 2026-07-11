defmodule RuleMavenWeb.AdminLive.Bgg do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      {:ok,
       assign(socket,
         page_title: "BoardGameGeek",
         saved: false,
         bgg_api_key: Settings.get("bgg_api_key") || "",
         bgg_user: Settings.get("bgg_user") || "",
         bgg_pass: Settings.get("bgg_pass") || ""
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    fields = %{
      "bgg_api_key" => params["bgg_api_key"],
      "bgg_user" => params["bgg_user"],
      "bgg_pass" => params["bgg_pass"]
    }

    Enum.each(fields, fn {key, val} ->
      trimmed = if is_binary(val), do: String.trim(val), else: val
      save_setting(key, trimmed)
    end)

    {:noreply,
     assign(socket,
       bgg_api_key: fields["bgg_api_key"] |> trim(),
       bgg_user: fields["bgg_user"] |> trim(),
       bgg_pass: fields["bgg_pass"] |> trim(),
       saved: true
     )}
  end

  defp save_setting(_key, ""), do: :ok
  defp save_setting(key, value), do: Settings.put(key, value)

  defp trim(nil), do: ""
  defp trim(s), do: String.trim(s)

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:48rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Admin</.link>
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">BoardGameGeek</h1>
      <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1.25rem">
        Used to import your game collection and download rulebook PDFs from BGG.
      </p>

      <div :if={@saved} class="alert alert-info mb-4">
        Settings saved.
      </div>

      <form phx-submit="save" style="display:flex;flex-direction:column;gap:1.25rem">
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
          <div style="display:flex;flex-direction:column;gap:0.75rem">
            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                API Token
              </label>
              <input
                type="password"
                name="bgg_api_key"
                id="bgg_api_key"
                value={@bgg_api_key}
                placeholder="Bearer token..."
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              />
              <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                Register at boardgamegeek.com/applications
              </p>
            </div>

            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                Username
              </label>
              <input
                type="text"
                name="bgg_user"
                id="bgg_user"
                value={@bgg_user}
                placeholder="BGG login username"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              />
            </div>

            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                Password
              </label>
              <input
                type="password"
                name="bgg_pass"
                id="bgg_pass"
                value={@bgg_pass}
                placeholder="BGG login password"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              />
              <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                Stored locally. Never shared.
              </p>
            </div>
          </div>
        </section>

        <button type="submit" class="btn-primary" style="align-self:flex-start">
          Save Settings
        </button>
      </form>
    </div>
    """
  end
end
