defmodule RuleMavenWeb.SettingsLive do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  # OpenRouter model menu, shared by the Answer / Cleanup / Vision selects so the
  # list lives in one place. `vision: true` means multimodal (image input) — the
  # Vision select shows only those. Slugs/prices verified against the OpenRouter
  # API; refresh here when the catalog moves.
  @openrouter_models [
    {"google/gemini-3.1-pro-preview", "Gemini 3.1 Pro — $2/$12, best vision/OCR", true},
    {"google/gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite — $0.25/$1.50, cheap + strong", true},
    {"google/gemini-3-flash-preview", "Gemini 3 Flash — $0.50/$3, 1M ctx", true},
    {"google/gemini-2.5-pro", "Gemini 2.5 Pro — $1.25/$10, 1M ctx", true},
    {"google/gemini-2.5-flash", "Gemini 2.5 Flash — $0.30/$2.50, great value", true},
    {"google/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite — $0.10/$0.40, cheapest", true},
    {"anthropic/claude-opus-4.8", "Claude Opus 4.8 — $5/$25, max accuracy", true},
    {"anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6 — $3/$15", true},
    {"anthropic/claude-haiku-4.5", "Claude Haiku 4.5 — $1/$5", true},
    {"openai/gpt-5.1", "GPT-5.1 — $1.25/$10", true},
    {"openai/gpt-5-mini", "GPT-5 Mini — $0.25/$2", true},
    {"openai/gpt-4o-mini", "GPT-4o Mini — $0.15/$0.60", true},
    {"meta-llama/llama-4-maverick", "Llama 4 Maverick — $0.15/$0.60, multimodal", true},
    {"meta-llama/llama-4-scout", "Llama 4 Scout — $0.10/$0.30, 10M ctx", true},
    {"deepseek/deepseek-v4-flash", "DeepSeek V4 Flash — $0.09/$0.18, fast (text only)", false},
    {"deepseek/deepseek-chat", "DeepSeek V3 — $0.20/$0.80 (text only)", false},
    {"deepseek/deepseek-r1", "DeepSeek R1 — $0.70/$2.50, reasoning (text only)", false}
  ]

  # <option> list for an OpenRouter model <select>. Marks the current value
  # selected; pass `vision_only` to limit it to multimodal models.
  attr :selected, :string, default: ""
  attr :vision_only, :boolean, default: false

  defp or_model_options(assigns) do
    assigns =
      assign(assigns,
        models:
          if(assigns.vision_only,
            do: Enum.filter(@openrouter_models, fn {_, _, v} -> v end),
            else: @openrouter_models
          )
      )

    ~H"""
    <option :for={{id, label, _vision} <- @models} value={id} selected={@selected == id}>
      {label}
    </option>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    admin? = Users.game_master?(user)

    {:ok,
     assign(socket,
       page_title: "Settings",
       profile_username: user.username,
       profile_email: user.email,
       profile_msg: nil,
       profile_error: nil,
       password_msg: nil,
       password_error: nil,
       is_admin: admin?,
       bgg_api_key: (admin? && Settings.get("bgg_api_key")) || "",
       bgg_user: (admin? && Settings.get("bgg_user")) || "",
       bgg_pass: (admin? && Settings.get("bgg_pass")) || "",
       llm_provider: (admin? && Settings.get("llm_provider")) || "openrouter",
       llm_key_openrouter: (admin? && Settings.get("llm_api_key_openrouter")) || "",
       llm_key_groq: (admin? && Settings.get("llm_api_key_groq")) || "",
       llm_key_gemini: (admin? && Settings.get("llm_api_key_gemini")) || "",
       llm_model_openrouter:
         (admin? && Settings.get("llm_model_openrouter")) || "google/gemini-2.5-flash",
       llm_model_groq: (admin? && Settings.get("llm_model_groq")) || "llama-3.3-70b-versatile",
       llm_model_gemini: (admin? && Settings.get("llm_model_gemini")) || "gemini-2.5-flash",
       llm_model_ollama: (admin? && Settings.get("llm_model_ollama")) || "mistral",
       # Optional per-provider override for rulebook cleanup. Blank = use the
       # answering model above.
       llm_cleanup_model_openrouter:
         (admin? && Settings.get("llm_cleanup_model_openrouter")) || "",
       llm_cleanup_model_groq: (admin? && Settings.get("llm_cleanup_model_groq")) || "",
       llm_cleanup_model_gemini: (admin? && Settings.get("llm_cleanup_model_gemini")) || "",
       llm_cleanup_model_ollama: (admin? && Settings.get("llm_cleanup_model_ollama")) || "",
       # Optional per-provider override for vision OCR (re-reading graphic pages).
       # Blank = use the answering model above; it MUST be multimodal.
       llm_vision_model_openrouter: (admin? && Settings.get("llm_vision_model_openrouter")) || "",
       llm_vision_model_groq: (admin? && Settings.get("llm_vision_model_groq")) || "",
       llm_vision_model_gemini: (admin? && Settings.get("llm_vision_model_gemini")) || "",
       llm_vision_model_ollama: (admin? && Settings.get("llm_vision_model_ollama")) || "",
       # Stronger/higher-res model used only to re-read pages the default vision
       # model failed on. Blank = reuse the vision model above; MUST be multimodal.
       llm_vision_escalate_model_openrouter:
         (admin? && Settings.get("llm_vision_escalate_model_openrouter")) || "",
       llm_vision_escalate_model_groq:
         (admin? && Settings.get("llm_vision_escalate_model_groq")) || "",
       llm_vision_escalate_model_gemini:
         (admin? && Settings.get("llm_vision_escalate_model_gemini")) || "",
       llm_vision_escalate_model_ollama:
         (admin? && Settings.get("llm_vision_escalate_model_ollama")) || "",
       # Rulebook extraction mode: "vision" (transcribe every page image — highest
       # accuracy) or "ocr" (pdftotext + OCR, vision only on junk pages).
       rulebook_extract_mode: (admin? && Settings.get("rulebook_extract_mode")) || "vision",
       embedding_provider: (admin? && Settings.get("embedding_provider")) || "openrouter",
       embedding_model:
         (admin? && Settings.get("embedding_model")) || "openai/text-embedding-3-small",
       embedding_key: (admin? && Settings.get("embedding_api_key_openrouter")) || "",
       auto_approve_docs: (admin? && Settings.get("auto_approve_documents")) || "true",
       auto_approve_faqs: (admin? && Settings.get("auto_approve_faqs")) || "true",
       pool_similarity_threshold: (admin? && Settings.get("pool_similarity_threshold")) || "0.92",
       cluster_similarity_threshold:
         (admin? && Settings.get("cluster_similarity_threshold")) || "0.85",
       llm_proxy_url: (admin? && Settings.get("llm_proxy_url")) || "",
       saved: false,
       usage_stats: nil,
       page_title: "Settings"
     )}
  end

  @impl true
  def handle_event("update_profile", %{"username" => username, "email" => email}, socket) do
    user = socket.assigns.current_user

    case Users.update_profile(user, %{username: String.trim(username), email: String.trim(email)}) do
      {:ok, updated} ->
        {:noreply,
         assign(socket,
           profile_username: updated.username,
           profile_email: updated.email,
           profile_msg: "Profile updated.",
           profile_error: nil
         )}

      {:error, changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, profile_error: msg, profile_msg: nil)}
    end
  end

  def handle_event(
        "change_password",
        %{"current_password" => current, "new_password" => new, "confirm_password" => confirm},
        socket
      ) do
    cond do
      new != confirm ->
        {:noreply,
         assign(socket, password_error: "New passwords don't match.", password_msg: nil)}

      true ->
        user = socket.assigns.current_user

        case Users.change_password(user, current, new) do
          {:ok, _} ->
            {:noreply,
             assign(socket,
               password_msg: "Password changed.",
               password_error: nil
             )}

          {:error, reason} ->
            {:noreply, assign(socket, password_error: reason, password_msg: nil)}
        end
    end
  end

  def handle_event("profile_form_change", params, socket) do
    socket =
      Enum.reduce(
        [:profile_username, :profile_email, :current_password, :new_password, :confirm_password],
        socket,
        fn field, acc ->
          key = Atom.to_string(field)
          if Map.has_key?(params, key), do: assign(acc, field, params[key]), else: acc
        end
      )

    {:noreply,
     assign(socket, profile_msg: nil, profile_error: nil, password_msg: nil, password_error: nil)}
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
    if socket.assigns.is_admin do
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
        "llm_cleanup_model_openrouter" => params["llm_cleanup_model_openrouter"],
        "llm_cleanup_model_groq" => params["llm_cleanup_model_groq"],
        "llm_cleanup_model_gemini" => params["llm_cleanup_model_gemini"],
        "llm_cleanup_model_ollama" => params["llm_cleanup_model_ollama"],
        "llm_vision_model_openrouter" => params["llm_vision_model_openrouter"],
        "llm_vision_model_groq" => params["llm_vision_model_groq"],
        "llm_vision_model_gemini" => params["llm_vision_model_gemini"],
        "llm_vision_model_ollama" => params["llm_vision_model_ollama"],
        "llm_vision_escalate_model_openrouter" => params["llm_vision_escalate_model_openrouter"],
        "llm_vision_escalate_model_groq" => params["llm_vision_escalate_model_groq"],
        "llm_vision_escalate_model_gemini" => params["llm_vision_escalate_model_gemini"],
        "llm_vision_escalate_model_ollama" => params["llm_vision_escalate_model_ollama"],
        "rulebook_extract_mode" => params["rulebook_extract_mode"],
        "embedding_provider" => params["embedding_provider"],
        "embedding_model" => params["embedding_model"],
        "embedding_api_key_openrouter" => params["embedding_key"],
        "auto_approve_documents" => params["auto_approve_docs"],
        "auto_approve_faqs" => params["auto_approve_faqs"],
        "pool_similarity_threshold" => params["pool_similarity_threshold"],
        "cluster_similarity_threshold" => params["cluster_similarity_threshold"],
        "llm_proxy_url" => params["llm_proxy_url"]
      }

      Enum.each(fields, fn {key, val} ->
        trimmed = if is_binary(val), do: String.trim(val), else: val
        save_setting(key, trimmed)
      end)

      # Cleanup- and vision-model overrides are optional: a blank field must clear
      # the override (fall back to the answering model), which the empty-skipping
      # save_setting/2 can't express — so delete those keys explicitly when blank.
      Enum.each(
        ~w(llm_cleanup_model_openrouter llm_cleanup_model_groq llm_cleanup_model_gemini llm_cleanup_model_ollama
           llm_vision_model_openrouter llm_vision_model_groq llm_vision_model_gemini llm_vision_model_ollama
           llm_vision_escalate_model_openrouter llm_vision_escalate_model_groq llm_vision_escalate_model_gemini llm_vision_escalate_model_ollama),
        fn key ->
          if trim(params[key]) == "", do: Settings.delete(key)
        end
      )

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
         llm_cleanup_model_openrouter: fields["llm_cleanup_model_openrouter"] |> trim(),
         llm_cleanup_model_groq: fields["llm_cleanup_model_groq"] |> trim(),
         llm_cleanup_model_gemini: fields["llm_cleanup_model_gemini"] |> trim(),
         llm_cleanup_model_ollama: fields["llm_cleanup_model_ollama"] |> trim(),
         llm_vision_model_openrouter: fields["llm_vision_model_openrouter"] |> trim(),
         llm_vision_model_groq: fields["llm_vision_model_groq"] |> trim(),
         llm_vision_model_gemini: fields["llm_vision_model_gemini"] |> trim(),
         llm_vision_model_ollama: fields["llm_vision_model_ollama"] |> trim(),
         llm_vision_escalate_model_openrouter:
           fields["llm_vision_escalate_model_openrouter"] |> trim(),
         llm_vision_escalate_model_groq: fields["llm_vision_escalate_model_groq"] |> trim(),
         llm_vision_escalate_model_gemini: fields["llm_vision_escalate_model_gemini"] |> trim(),
         llm_vision_escalate_model_ollama: fields["llm_vision_escalate_model_ollama"] |> trim(),
         rulebook_extract_mode: fields["rulebook_extract_mode"] |> trim(),
         embedding_provider: fields["embedding_provider"] |> trim(),
         embedding_model: fields["embedding_model"] |> trim(),
         embedding_key: fields["embedding_api_key_openrouter"] |> trim(),
         auto_approve_docs: fields["auto_approve_documents"] |> trim(),
         auto_approve_faqs: fields["auto_approve_faqs"] |> trim(),
         pool_similarity_threshold: fields["pool_similarity_threshold"] |> trim(),
         cluster_similarity_threshold: fields["cluster_similarity_threshold"] |> trim(),
         llm_proxy_url: fields["llm_proxy_url"] |> trim(),
         saved: true
       )}
    else
      {:noreply, assign(socket, saved: true)}
    end
  end

  defp save_setting(_key, ""), do: :ok
  defp save_setting(key, value), do: Settings.put(key, value)

  defp trim(nil), do: ""
  defp trim(s), do: String.trim(s)

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      if socket.assigns.live_action == :usage and socket.assigns.is_admin do
        stats = RuleMaven.LLM.stats(30)
        assign(socket, usage_stats: stats, page_title: "Usage")
      else
        assign(socket, usage_stats: nil, page_title: "Settings")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-page" style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem 3rem">
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

        <!-- Profile Section -->
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface);margin-bottom:1rem">
          <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.75rem 0">Profile</h2>

          <div phx-change="profile_form_change">
            <!-- Username & Email -->
            <div style="display:flex;gap:0.75rem;flex-wrap:wrap;margin-bottom:0.75rem">
              <div style="flex:1;min-width:10rem">
                <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Username</label>
                <input
                  type="text"
                  name="profile_username"
                  value={@profile_username}
                  style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
                />
              </div>
              <div style="flex:1;min-width:10rem">
                <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text);margin-bottom:0.2rem">Email</label>
                <input
                  type="email"
                  name="profile_email"
                  value={@profile_email}
                  style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
                />
              </div>
            </div>
            <div style="display:flex;gap:0.5rem;align-items:center">
              <button
                type="button"
                phx-click="update_profile"
                phx-value-username={@profile_username}
                phx-value-email={@profile_email}
                style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.78rem;font-weight:600;cursor:pointer"
              >Save Profile</button>
              <%= if @profile_msg do %>
                <span style="font-size:0.75rem;color:var(--green)">{@profile_msg}</span>
              <% end %>
              <%= if @profile_error do %>
                <span style="font-size:0.75rem;color:var(--red)">{@profile_error}</span>
              <% end %>
            </div>

            <!-- Change Password -->
            <div style="margin-top:1rem;padding-top:1rem;border-top:1px solid var(--border)">
              <h3 style="font-size:0.82rem;font-weight:600;margin:0 0 0.5rem 0">Change Password</h3>
              <form
                phx-submit="change_password"
                style="display:flex;flex-direction:column;gap:0.5rem;max-width:20rem"
              >
                <input
                  type="password"
                  name="current_password"
                  placeholder="Current password"
                  style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
                />
                <input
                  type="password"
                  name="new_password"
                  placeholder="New password"
                  style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
                />
                <input
                  type="password"
                  name="confirm_password"
                  placeholder="Confirm new password"
                  style="width:100%;border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.6rem;font-size:0.82rem;background:var(--bg);color:var(--text)"
                />
                <div style="display:flex;gap:0.5rem;align-items:center">
                  <button
                    type="submit"
                    style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.78rem;font-weight:600;cursor:pointer"
                  >Change Password</button>
                  <%= if @password_msg do %>
                    <span style="font-size:0.75rem;color:var(--green)">{@password_msg}</span>
                  <% end %>
                  <%= if @password_error do %>
                    <span style="font-size:0.75rem;color:var(--red)">{@password_error}</span>
                  <% end %>
                </div>
              </form>
            </div>
          </div>
        </section>

        <%= if @is_admin do %>
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
                    Answer model
                  </label>
                  <select
                    name="llm_model_openrouter"
                    id="llm_model_openrouter"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <.or_model_options selected={@llm_model_openrouter} />
                  </select>
                </div>

                <div :if={@llm_provider == "openrouter"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Cleanup model
                    <span style="font-weight:400;color:var(--text-muted)">— optional, blank = use Model above</span>
                  </label>
                  <select
                    name="llm_cleanup_model_openrouter"
                    id="llm_cleanup_model_openrouter"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_cleanup_model_openrouter == ""}>
                      Use Answer model
                    </option>
                    <.or_model_options selected={@llm_cleanup_model_openrouter} />
                  </select>
                </div>

                <div :if={@llm_provider == "openrouter"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Vision model
                    <span style="font-weight:400;color:var(--text-muted)">— re-reads graphic pages OCR can't; must be multimodal. Blank = use Answer model</span>
                  </label>
                  <select
                    name="llm_vision_model_openrouter"
                    id="llm_vision_model_openrouter"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_vision_model_openrouter == ""}>
                      Use Answer model
                    </option>
                    <.or_model_options selected={@llm_vision_model_openrouter} vision_only={true} />
                  </select>
                </div>

                <div :if={@llm_provider == "openrouter"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Vision escalation model
                    <span style="font-weight:400;color:var(--text-muted)">— stronger/higher-res re-read for pages the Vision model fails on; must be multimodal. Blank = use Vision model</span>
                  </label>
                  <select
                    name="llm_vision_escalate_model_openrouter"
                    id="llm_vision_escalate_model_openrouter"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_vision_escalate_model_openrouter == ""}>
                      Use Vision model
                    </option>
                    <.or_model_options
                      selected={@llm_vision_escalate_model_openrouter}
                      vision_only={true}
                    />
                  </select>
                </div>

                <div>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Rulebook extraction
                    <span style="font-weight:400;color:var(--text-muted)">— how page text is read from the PDF</span>
                  </label>
                  <select
                    name="rulebook_extract_mode"
                    id="rulebook_extract_mode"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="vision" selected={@rulebook_extract_mode == "vision"}>
                      Vision — transcribe every page image (highest accuracy)
                    </option>
                    <option value="ocr" selected={@rulebook_extract_mode == "ocr"}>
                      OCR — text layer + OCR, vision only on bad pages (cheaper)
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
                    Answer model
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

                <div :if={@llm_provider == "groq"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Cleanup model
                    <span style="font-weight:400;color:var(--text-muted)">— optional, blank = use Model above</span>
                  </label>
                  <select
                    name="llm_cleanup_model_groq"
                    id="llm_cleanup_model_groq"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_cleanup_model_groq == ""}>
                      Use Answer model
                    </option>
                    <option
                      value="llama-3.3-70b-versatile"
                      selected={@llm_cleanup_model_groq == "llama-3.3-70b-versatile"}
                    >
                      Llama 3.3 70B
                    </option>
                    <option
                      value="llama-3.1-8b-instant"
                      selected={@llm_cleanup_model_groq == "llama-3.1-8b-instant"}
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
                    Answer model
                  </label>
                  <select
                    name="llm_model_gemini"
                    id="llm_model_gemini"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option
                      value="gemini-2.5-flash"
                      selected={@llm_model_gemini == "gemini-2.5-flash"}
                    >
                      Gemini 2.5 Flash
                    </option>
                    <option
                      value="gemini-2.0-flash"
                      selected={@llm_model_gemini == "gemini-2.0-flash"}
                    >
                      Gemini 2.0 Flash
                    </option>
                  </select>
                </div>

                <div :if={@llm_provider == "gemini"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Cleanup model
                    <span style="font-weight:400;color:var(--text-muted)">— optional, blank = use Model above</span>
                  </label>
                  <select
                    name="llm_cleanup_model_gemini"
                    id="llm_cleanup_model_gemini"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_cleanup_model_gemini == ""}>
                      Use Answer model
                    </option>
                    <option
                      value="gemini-2.5-flash"
                      selected={@llm_cleanup_model_gemini == "gemini-2.5-flash"}
                    >
                      Gemini 2.5 Flash
                    </option>
                    <option
                      value="gemini-2.0-flash"
                      selected={@llm_cleanup_model_gemini == "gemini-2.0-flash"}
                    >
                      Gemini 2.0 Flash
                    </option>
                  </select>
                </div>

                <%!-- Ollama --%>
                <div :if={@llm_provider == "ollama"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Answer model
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

                <div :if={@llm_provider == "ollama"}>
                  <label style="display:block;font-size:0.8rem;font-weight:600;margin-bottom:0.25rem">
                    Cleanup model
                    <span style="font-weight:400;color:var(--text-muted)">— optional, blank = use Model above</span>
                  </label>
                  <select
                    name="llm_cleanup_model_ollama"
                    id="llm_cleanup_model_ollama"
                    style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
                  >
                    <option value="" selected={@llm_cleanup_model_ollama == ""}>
                      Use Answer model
                    </option>
                    <option value="mistral" selected={@llm_cleanup_model_ollama == "mistral"}>
                      Mistral 7B
                    </option>
                    <option value="llama3.2" selected={@llm_cleanup_model_ollama == "llama3.2"}>
                      Llama 3.2 3B
                    </option>
                    <option value="llama3.1:8b" selected={@llm_cleanup_model_ollama == "llama3.1:8b"}>
                      Llama 3.1 8B
                    </option>
                  </select>
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
      <% end %>
    </div>
    """
  end
end
