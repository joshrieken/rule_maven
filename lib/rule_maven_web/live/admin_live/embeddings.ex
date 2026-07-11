defmodule RuleMavenWeb.AdminLive.Embeddings do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket,
         page_title: "Embeddings & Proxy",
         saved: false,
         embedding_provider: Settings.get("embedding_provider") || "openrouter",
         embedding_model: Settings.get("embedding_model") || "openai/text-embedding-3-small",
         embedding_key: Settings.get("embedding_api_key_openrouter") || "",
         llm_proxy_url: Settings.get("llm_proxy_url") || ""
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("select_embedding_provider", %{"embedding_provider" => provider}, socket) do
    {:noreply, assign(socket, embedding_provider: provider)}
  end

  @impl true
  def handle_event("save", params, socket) do
    fields = %{
      "embedding_provider" => params["embedding_provider"],
      "embedding_model" => params["embedding_model"],
      "embedding_api_key_openrouter" => params["embedding_key"],
      "llm_proxy_url" => params["llm_proxy_url"]
    }

    Enum.each(fields, fn {key, val} ->
      trimmed = if is_binary(val), do: String.trim(val), else: val
      save_setting(key, trimmed)
    end)

    {:noreply,
     assign(socket,
       embedding_provider: fields["embedding_provider"] |> trim(),
       embedding_model: fields["embedding_model"] |> trim(),
       embedding_key: fields["embedding_api_key_openrouter"] |> trim(),
       llm_proxy_url: fields["llm_proxy_url"] |> trim(),
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
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">Embeddings & Proxy</h1>

      <div :if={@saved} class="alert alert-info mb-4">
        Settings saved.
      </div>

      <form phx-submit="save" style="display:flex;flex-direction:column;gap:1.25rem">
        <%!-- ════════════════════════════════════════ --%>
        <%!-- Embeddings --%>
        <%!-- ════════════════════════════════════════ --%>
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
          <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.25rem 0">Embeddings</h2>
          <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem 0">
            Used for semantic search over rulebook chunks and FAQ similarity matching. Generated once at upload time, once per question.
          </p>

          <div style="display:flex;flex-direction:column;gap:0.75rem">
            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                Provider
              </label>
              <select
                name="embedding_provider"
                id="embedding_provider"
                phx-change="select_embedding_provider"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              >
                <option value="openrouter" selected={@embedding_provider == "openrouter"}>
                  OpenRouter
                </option>
                <option value="ollama" selected={@embedding_provider == "ollama"}>
                  Ollama — local, zero cost
                </option>
              </select>
            </div>

            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                Model
              </label>
              <select
                name="embedding_model"
                id="embedding_model"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              >
                <option
                  value="openai/text-embedding-3-small"
                  selected={@embedding_model == "openai/text-embedding-3-small"}
                >
                  text-embedding-3-small — 768-dim
                </option>
                <option
                  value="openai/text-embedding-3-large"
                  selected={@embedding_model == "openai/text-embedding-3-large"}
                >
                  text-embedding-3-large — 3072-dim
                </option>
                <option value="nomic-embed-text" selected={@embedding_model == "nomic-embed-text"}>
                  nomic-embed-text — Ollama, 768-dim
                </option>
              </select>
            </div>

            <div :if={@embedding_provider == "openrouter"}>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                API Key (optional)
              </label>
              <input
                type="password"
                name="embedding_key"
                id="embedding_key"
                value={@embedding_key}
                placeholder="Uses LLM key if empty..."
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              />
              <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                Falls back to OpenRouter LLM key if left blank.
              </p>
            </div>
          </div>
        </section>

        <%!-- ════════════════════════════════════════ --%>
        <%!-- LLM Proxy --%>
        <%!-- ════════════════════════════════════════ --%>
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
          <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.25rem 0">LLM Proxy</h2>
          <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem 0">
            Route all LLM and embedding calls through a proxy (e.g. Headroom). Leave blank to call providers directly.
          </p>

          <div style="display:flex;flex-direction:column;gap:0.75rem">
            <div>
              <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                Proxy URL
              </label>
              <input
                type="text"
                name="llm_proxy_url"
                id="llm_proxy_url"
                value={@llm_proxy_url}
                placeholder="http://localhost:8787"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              />
              <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                Calls will be sent to PROXY_URL/v1/chat/completions and PROXY_URL/v1/embeddings. Proxy handles upstream routing.
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
