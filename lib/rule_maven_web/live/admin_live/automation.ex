defmodule RuleMavenWeb.AdminLive.Automation do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      {:ok,
       assign(socket,
         page_title: "Automation",
         saved: false,
         auto_approve_docs: Settings.get("auto_approve_documents") || "true",
         auto_approve_faqs: Settings.get("auto_approve_faqs") || "true",
         pool_similarity_threshold: Settings.get("pool_similarity_threshold") || "0.92",
         cluster_similarity_threshold: Settings.get("cluster_similarity_threshold") || "0.85"
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    fields = %{
      "auto_approve_documents" => params["auto_approve_docs"],
      "auto_approve_faqs" => params["auto_approve_faqs"],
      "pool_similarity_threshold" => params["pool_similarity_threshold"],
      "cluster_similarity_threshold" => params["cluster_similarity_threshold"]
    }

    Enum.each(fields, fn {key, val} ->
      trimmed = if is_binary(val), do: String.trim(val), else: val
      save_setting(key, trimmed)
    end)

    {:noreply,
     assign(socket,
       auto_approve_docs: fields["auto_approve_documents"] |> trim(),
       auto_approve_faqs: fields["auto_approve_faqs"] |> trim(),
       pool_similarity_threshold: fields["pool_similarity_threshold"] |> trim(),
       cluster_similarity_threshold: fields["cluster_similarity_threshold"] |> trim(),
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
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">Automation</h1>
      <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1.25rem">
        Reduce manual admin work. Auto-approve when confidence is high. Disable to review everything manually.
      </p>

      <div :if={@saved} class="alert alert-info mb-4">
        Settings saved.
      </div>

      <form phx-submit="save" style="display:flex;flex-direction:column;gap:1.25rem">
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
          <div style="display:flex;flex-direction:column;gap:0.75rem">
            <label style="display:flex;align-items:center;gap:0.5rem;cursor:pointer">
              <input
                type="checkbox"
                name="auto_approve_docs"
                id="auto_approve_docs"
                value="true"
                checked={@auto_approve_docs == "true"}
              />
              <span style="font-size:0.85rem">
                Auto-publish clean document uploads
                <span style="display:block;font-size:0.7rem;color:var(--text-muted)">
                  Skips review when extraction is clean
                </span>
              </span>
            </label>

            <label style="display:flex;align-items:center;gap:0.5rem;cursor:pointer">
              <input
                type="checkbox"
                name="auto_approve_faqs"
                id="auto_approve_faqs"
                value="true"
                checked={@auto_approve_faqs == "true"}
              />
              <span style="font-size:0.85rem">
                Auto-publish high-confidence FAQ drafts
                <span style="display:block;font-size:0.7rem;color:var(--text-muted)">
                  Skips review when all source Q&amp;As are upvoted, no disagreements
                </span>
              </span>
            </label>

            <label style="display:flex;flex-direction:column;gap:0.25rem">
              <span style="font-size:0.85rem">
                Community pool match threshold
                <span style="display:block;font-size:0.7rem;color:var(--text-muted)">
                  Min cosine similarity (0–1) for a cached community answer to be served. Higher = stricter. Default 0.92.
                </span>
              </span>
              <input
                type="number"
                name="pool_similarity_threshold"
                id="pool_similarity_threshold"
                step="0.01"
                min="0"
                max="1"
                value={@pool_similarity_threshold}
                style="width:7rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg)"
              />
            </label>

            <label style="display:flex;flex-direction:column;gap:0.25rem">
              <span style="font-size:0.85rem">
                Promotion clustering threshold
                <span style="display:block;font-size:0.7rem;color:var(--text-muted)">
                  Min cosine similarity (0–1) to group upvoted questions when promoting to the community pool. Default 0.85.
                </span>
              </span>
              <input
                type="number"
                name="cluster_similarity_threshold"
                id="cluster_similarity_threshold"
                step="0.01"
                min="0"
                max="1"
                value={@cluster_similarity_threshold}
                style="width:7rem;padding:0.35rem 0.5rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg)"
              />
            </label>
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
