defmodule RuleMavenWeb.SettingsLive do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       bgg_api_key: Settings.get("bgg_api_key") || "",
       bgg_user: Settings.get("bgg_user") || "",
       bgg_pass: Settings.get("bgg_pass") || "",
       llm_provider: Settings.get("llm_provider") || "openrouter",
       llm_key_openrouter: Settings.get("llm_api_key_openrouter") || "",
       llm_key_groq: Settings.get("llm_api_key_groq") || "",
       llm_key_gemini: Settings.get("llm_api_key_gemini") || "",
       llm_model_openrouter: Settings.get("llm_model_openrouter") || "google/gemini-2.5-flash",
       llm_model_groq: Settings.get("llm_model_groq") || "llama-3.3-70b-versatile",
       llm_model_gemini: Settings.get("llm_model_gemini") || "gemini-2.5-flash",
       llm_model_ollama: Settings.get("llm_model_ollama") || "mistral",
       embedding_provider: Settings.get("embedding_provider") || "openrouter",
       embedding_model: Settings.get("embedding_model") || "openai/text-embedding-3-small",
       embedding_key: Settings.get("embedding_api_key_openrouter") || "",
       auto_approve_docs: Settings.get("auto_approve_documents") || "true",
       auto_approve_faqs: Settings.get("auto_approve_faqs") || "true",
       saved: false,
       usage_stats: nil,
       page_title: "Settings"
     )}
  end

  @impl true
  def handle_event("select_provider", %{"llm_provider" => provider}, socket) do
    {:noreply, assign(socket, llm_provider: provider)}
  end

  @impl true
  def handle_event("select_embedding_provider", %{"embedding_provider" => provider}, socket) do
    {:noreply, assign(socket, embedding_provider: provider)}
  end

  @impl true
  def handle_event("save", params, socket) do
    fields = %{
      "bgg_api_key" => params["bgg_api_key"],
      "bgg_user" => params["bgg_user"],
      "bgg_pass" => params["bgg_pass"],
      "llm_provider" => params["llm_provider"],
      "llm_api_key_openrouter" => params["llm_key_openrouter"],
      "llm_api_key_groq" => params["llm_key_groq"],
      "llm_api_key_gemini" => params["llm_key_gemini"],
      "llm_model_openrouter" => params["llm_model_openrouter"],
      "llm_model_groq" => params["llm_model_groq"],
      "llm_model_gemini" => params["llm_model_gemini"],
      "llm_model_ollama" => params["llm_model_ollama"],
      "embedding_provider" => params["embedding_provider"],
      "embedding_model" => params["embedding_model"],
      "embedding_api_key_openrouter" => params["embedding_key"],
      "auto_approve_documents" => params["auto_approve_docs"],
      "auto_approve_faqs" => params["auto_approve_faqs"]
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
       llm_provider: fields["llm_provider"] |> trim(),
       llm_key_openrouter: fields["llm_api_key_openrouter"] |> trim(),
       llm_key_groq: fields["llm_api_key_groq"] |> trim(),
       llm_key_gemini: fields["llm_api_key_gemini"] |> trim(),
       llm_model_openrouter: fields["llm_model_openrouter"] |> trim(),
       llm_model_groq: fields["llm_model_groq"] |> trim(),
       llm_model_gemini: fields["llm_model_gemini"] |> trim(),
       llm_model_ollama: fields["llm_model_ollama"] |> trim(),
       embedding_provider: fields["embedding_provider"] |> trim(),
       embedding_model: fields["embedding_model"] |> trim(),
       embedding_key: fields["embedding_api_key_openrouter"] |> trim(),
       auto_approve_docs: fields["auto_approve_documents"] |> trim(),
       auto_approve_faqs: fields["auto_approve_faqs"] |> trim(),
       saved: true
     )}
  end

  defp save_setting(_key, ""), do: :ok
  defp save_setting(key, value), do: Settings.put(key, value)

  defp trim(nil), do: ""
  defp trim(s), do: String.trim(s)

  @impl true
  def handle_params(_params, _uri, socket) do
    if RuleMaven.Users.game_master?(socket.assigns.current_user) do
      socket =
        if socket.assigns.live_action == :usage do
          stats = RuleMaven.LLM.stats(30)
          assign(socket, usage_stats: stats, page_title: "Usage")
        else
          assign(socket, usage_stats: nil, page_title: "Settings")
        end

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-page" style="max-width:640px;margin:0 auto;padding:1.5rem 1rem 3rem">
      <%= if @usage_stats do %>
        <div class="mb-4">
          <.link navigate={~p"/settings"} class="back-link">&larr; Settings</.link>
        </div>

        <h1 class="text-2xl font-bold mb-4">LLM Usage (30 days)</h1>

        <div style="display:flex;flex-direction:column;gap:1rem">
          <div style="display:flex;gap:2rem;flex-wrap:wrap">
            <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;min-width:120px">
              <p class="text-xs text-gray-500">Requests</p>
              <p class="text-2xl font-bold">{@usage_stats.total_requests}</p>
            </div>
            <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;min-width:120px">
              <p class="text-xs text-gray-500">Tokens</p>
              <p class="text-2xl font-bold">{@usage_stats.total_tokens}</p>
            </div>
            <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;min-width:120px">
              <p class="text-xs text-gray-500">Errors</p>
              <p class="text-2xl font-bold">{@usage_stats.error_count}</p>
            </div>
            <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem;min-width:120px">
              <p class="text-xs text-gray-500">Avg Duration</p>
              <p class="text-2xl font-bold">{@usage_stats.avg_duration_ms}ms</p>
            </div>
          </div>

          <div
            :if={@usage_stats.by_provider != []}
            style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1rem"
          >
            <h3 class="font-semibold text-sm mb-2">By Provider</h3>
            <table style="width:100%;font-size:0.8rem">
              <tr style="text-align:left;border-bottom:1px solid var(--border)">
                <th style="padding:0.25rem 0.5rem">Provider</th>
                <th style="padding:0.25rem 0.5rem">Requests</th>
                <th style="padding:0.25rem 0.5rem">Tokens</th>
              </tr>
              <%= for p <- @usage_stats.by_provider do %>
                <tr>
                  <td style="padding:0.25rem 0.5rem">{p.provider}</td>
                  <td style="padding:0.25rem 0.5rem">{p.requests}</td>
                  <td style="padding:0.25rem 0.5rem">{p.tokens}</td>
                </tr>
              <% end %>
            </table>
          </div>
        </div>
      <% else %>
        <div class="mb-4">
          <.link navigate={~p"/"} class="back-link">
            &larr; Back to games
          </.link>
        </div>

        <h1 class="text-2xl font-bold mb-2">Settings</h1>

        <div :if={@saved} class="alert alert-info mb-4">
          Settings saved.
        </div>

        <form phx-submit="save" style="display:flex;flex-direction:column;gap:1.25rem">
          <%!-- ════════════════════════════════════════ --%>
          <%!-- LLM Provider --%>
          <%!-- ════════════════════════════════════════ --%>
          <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
            <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.25rem 0">LLM Provider</h2>
            <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem 0">
              Select which LLM service to use for answering questions and generating content.
            </p>

            <div style="display:flex;flex-direction:column;gap:0.75rem">
              <div>
                <label
                  for="llm_provider"
                  style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem"
                >
                  Provider
                </label>
                <select
                  name="llm_provider"
                  id="llm_provider"
                  phx-change="select_provider"
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                >
                  <option value="openrouter" selected={@llm_provider == "openrouter"}>
                    OpenRouter — 200+ models, pay-as-you-go
                  </option>
                  <option value="groq" selected={@llm_provider == "groq"}>
                    Groq — free tier (fast Llama inference)
                  </option>
                  <option value="gemini" selected={@llm_provider == "gemini"}>
                    Google Gemini — free tier
                  </option>
                  <option value="ollama" selected={@llm_provider == "ollama"}>
                    Ollama — runs locally
                  </option>
                </select>
              </div>

              <%!-- OpenRouter --%>
              <div :if={@llm_provider == "openrouter"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  API Key
                </label>
                <input
                  type="password"
                  name="llm_key_openrouter"
                  id="llm_key_openrouter"
                  value={@llm_key_openrouter}
                  placeholder="sk-or-..."
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                />
                <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                  Get key at
                  <a href="https://openrouter.ai/keys" target="_blank" style="color:var(--blue)">openrouter.ai/keys</a>
                </p>
              </div>

              <div :if={@llm_provider == "openrouter"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  Model
                </label>
                <select
                  name="llm_model_openrouter"
                  id="llm_model_openrouter"
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                >
                  <option
                    value="google/gemini-2.5-flash"
                    selected={@llm_model_openrouter == "google/gemini-2.5-flash"}
                  >
                    Gemini 2.5 Flash — free, 1M ctx
                  </option>
                  <option
                    value="google/gemini-2.5-flash-lite"
                    selected={@llm_model_openrouter == "google/gemini-2.5-flash-lite"}
                  >
                    Gemini 2.5 Flash Lite — free, 1M ctx
                  </option>
                  <option
                    value="meta-llama/llama-4-scout"
                    selected={@llm_model_openrouter == "meta-llama/llama-4-scout"}
                  >
                    Llama 4 Scout — free, 10M ctx
                  </option>
                  <option
                    value="meta-llama/llama-4-maverick"
                    selected={@llm_model_openrouter == "meta-llama/llama-4-maverick"}
                  >
                    Llama 4 Maverick — free, 1M ctx
                  </option>
                  <option
                    value="meta-llama/llama-3.3-70b-instruct:free"
                    selected={@llm_model_openrouter == "meta-llama/llama-3.3-70b-instruct:free"}
                  >
                    Llama 3.3 70B — free
                  </option>
                  <option
                    value="anthropic/claude-3.5-haiku"
                    selected={@llm_model_openrouter == "anthropic/claude-3.5-haiku"}
                  >
                    Claude 3.5 Haiku — paid, fast
                  </option>
                  <option
                    value="anthropic/claude-sonnet-4"
                    selected={@llm_model_openrouter == "anthropic/claude-sonnet-4"}
                  >
                    Claude Sonnet 4 — paid, powerful
                  </option>
                  <option
                    value="deepseek/deepseek-chat"
                    selected={@llm_model_openrouter == "deepseek/deepseek-chat"}
                  >
                    DeepSeek V3 — free
                  </option>
                  <option
                    value="deepseek/deepseek-r1"
                    selected={@llm_model_openrouter == "deepseek/deepseek-r1"}
                  >
                    DeepSeek R1 — free, reasoning
                  </option>
                  <option
                    value="openai/gpt-4o-mini"
                    selected={@llm_model_openrouter == "openai/gpt-4o-mini"}
                  >
                    GPT-4o Mini — paid, cheap
                  </option>
                </select>
              </div>

              <%!-- Groq --%>
              <div :if={@llm_provider == "groq"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  API Key
                </label>
                <input
                  type="password"
                  name="llm_key_groq"
                  id="llm_key_groq"
                  value={@llm_key_groq}
                  placeholder="gsk_..."
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                />
              </div>

              <div :if={@llm_provider == "groq"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  Model
                </label>
                <select
                  name="llm_model_groq"
                  id="llm_model_groq"
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                >
                  <option
                    value="llama-3.3-70b-versatile"
                    selected={@llm_model_groq == "llama-3.3-70b-versatile"}
                  >
                    Llama 3.3 70B
                  </option>
                  <option
                    value="llama-3.1-8b-instant"
                    selected={@llm_model_groq == "llama-3.1-8b-instant"}
                  >
                    Llama 3.1 8B — fastest
                  </option>
                </select>
              </div>

              <%!-- Gemini --%>
              <div :if={@llm_provider == "gemini"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  API Key
                </label>
                <input
                  type="password"
                  name="llm_key_gemini"
                  id="llm_key_gemini"
                  value={@llm_key_gemini}
                  placeholder="AIza..."
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                />
              </div>

              <div :if={@llm_provider == "gemini"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  Model
                </label>
                <select
                  name="llm_model_gemini"
                  id="llm_model_gemini"
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                >
                  <option value="gemini-2.5-flash" selected={@llm_model_gemini == "gemini-2.5-flash"}>
                    Gemini 2.5 Flash
                  </option>
                  <option value="gemini-2.0-flash" selected={@llm_model_gemini == "gemini-2.0-flash"}>
                    Gemini 2.0 Flash
                  </option>
                </select>
              </div>

              <%!-- Ollama --%>
              <div :if={@llm_provider == "ollama"}>
                <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                  Model
                </label>
                <select
                  name="llm_model_ollama"
                  id="llm_model_ollama"
                  style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                >
                  <option value="mistral" selected={@llm_model_ollama == "mistral"}>
                    Mistral 7B
                  </option>
                  <option value="llama3.2" selected={@llm_model_ollama == "llama3.2"}>
                    Llama 3.2 3B
                  </option>
                  <option value="llama3.1:8b" selected={@llm_model_ollama == "llama3.1:8b"}>
                    Llama 3.1 8B
                  </option>
                </select>
                <p style="font-size:0.7rem;color:var(--text-muted);margin:0.25rem 0 0 0">
                  Pull with <code>ollama pull MODEL</code> first.
                </p>
              </div>
            </div>
          </section>

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
          <%!-- Automation --%>
          <%!-- ════════════════════════════════════════ --%>
          <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
            <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.25rem 0">Automation</h2>
            <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem 0">
              Reduce manual admin work. Auto-approve when confidence is high. Disable to review everything manually.
            </p>

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
            </div>
          </section>

          <%!-- ════════════════════════════════════════ --%>
          <%!-- BGG Integration --%>
          <%!-- ════════════════════════════════════════ --%>
          <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
            <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.25rem 0">BoardGameGeek</h2>
            <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 1rem 0">
              Used to import your game collection and download rulebook PDFs from BGG.
            </p>

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

          <button
            type="submit"
            style="background:var(--accent);color:white;border:none;padding:0.65rem 2rem;border-radius:0.5rem;font-weight:600;font-size:0.9rem;cursor:pointer;align-self:flex-start"
          >
            Save Settings
          </button>
        </form>
        <div class="mt-6 pt-4 border-t">
          <.link navigate={~p"/settings/usage"} class="text-blue-600 hover:underline text-sm">
            View LLM Usage &rarr;
          </.link>
        </div>
      <% end %>
    </div>
    """
  end
end
