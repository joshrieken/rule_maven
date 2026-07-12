defmodule RuleMavenWeb.AdminLive.Llm do
  use RuleMavenWeb, :live_view

  alias RuleMaven.Settings
  alias RuleMaven.Users

  # OpenRouter model menu, shared by the Answer / Cleanup / Vision selects so the
  # list lives in one place. `vision: true` means multimodal (image input) — the
  # Vision select shows only those. Slugs/prices verified against the OpenRouter
  # API; refresh here when the catalog moves.
  @openrouter_models [
    {"google/gemini-3.1-pro-preview", "Gemini 3.1 Pro — $2/$12, best vision/OCR", true},
    {"google/gemini-3.5-flash", "Gemini 3.5 Flash — $1.50/$9, newest flash", true},
    {"google/gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite — $0.25/$1.50, cheap + strong", true},
    {"google/gemini-3-flash-preview", "Gemini 3 Flash — $0.50/$3, 1M ctx", true},
    {"google/gemini-2.5-pro", "Gemini 2.5 Pro — $1.25/$10, 1M ctx", true},
    {"google/gemini-2.5-flash", "Gemini 2.5 Flash — $0.30/$2.50, great value", true},
    {"google/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite — $0.10/$0.40, cheapest", true},
    {"anthropic/claude-opus-4.8", "Claude Opus 4.8 — $5/$25, max accuracy", true},
    {"anthropic/claude-sonnet-5", "Claude Sonnet 5 — $2/$10, strong + cheap", true},
    {"anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6 — $3/$15", true},
    {"anthropic/claude-haiku-4.5", "Claude Haiku 4.5 — $1/$5", true},
    {"openai/gpt-5.2", "GPT-5.2 — $1.75/$14, flagship reasoning", true},
    {"openai/gpt-5.1", "GPT-5.1 — $1.25/$10", true},
    {"openai/gpt-5-mini", "GPT-5 Mini — $0.25/$2", true},
    {"openai/gpt-4o-mini", "GPT-4o Mini — $0.15/$0.60", true},
    {"meta-llama/llama-4-maverick", "Llama 4 Maverick — $0.20/$0.80, multimodal", true},
    {"meta-llama/llama-4-scout", "Llama 4 Scout — $0.10/$0.30, 10M ctx", true},
    {"deepseek/deepseek-v4-pro", "DeepSeek V4 Pro — $0.44/$0.87, reasoning (text only)", false},
    {"deepseek/deepseek-v4-flash", "DeepSeek V4 Flash — $0.08/$0.15, fast (text only)", false},
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
    if Users.can?(socket.assigns.current_user, :superadmin) do
      {:ok,
       assign(socket,
         page_title: "LLM Provider",
         saved: false,
         llm_provider: Settings.get("llm_provider") || "openrouter",
         llm_key_openrouter: Settings.get("llm_api_key_openrouter") || "",
         llm_key_groq: Settings.get("llm_api_key_groq") || "",
         llm_key_gemini: Settings.get("llm_api_key_gemini") || "",
         llm_model_openrouter: Settings.get("llm_model_openrouter") || "google/gemini-2.5-flash",
         llm_model_groq: Settings.get("llm_model_groq") || "llama-3.3-70b-versatile",
         llm_model_gemini: Settings.get("llm_model_gemini") || "gemini-2.5-flash",
         llm_model_ollama: Settings.get("llm_model_ollama") || "mistral",
         # Optional per-provider override for rulebook cleanup. Blank = use the
         # answering model above.
         llm_cleanup_model_openrouter: Settings.get("llm_cleanup_model_openrouter") || "",
         llm_cleanup_model_groq: Settings.get("llm_cleanup_model_groq") || "",
         llm_cleanup_model_gemini: Settings.get("llm_cleanup_model_gemini") || "",
         llm_cleanup_model_ollama: Settings.get("llm_cleanup_model_ollama") || "",
         # Optional per-provider override for vision OCR (re-reading graphic pages).
         # Blank = use the answering model above; it MUST be multimodal.
         llm_vision_model_openrouter: Settings.get("llm_vision_model_openrouter") || "",
         llm_vision_model_groq: Settings.get("llm_vision_model_groq") || "",
         llm_vision_model_gemini: Settings.get("llm_vision_model_gemini") || "",
         llm_vision_model_ollama: Settings.get("llm_vision_model_ollama") || "",
         # Stronger/higher-res model used only to re-read pages the default vision
         # model failed on. Blank = reuse the vision model above; MUST be multimodal.
         llm_vision_escalate_model_openrouter:
           Settings.get("llm_vision_escalate_model_openrouter") || "",
         llm_vision_escalate_model_groq: Settings.get("llm_vision_escalate_model_groq") || "",
         llm_vision_escalate_model_gemini: Settings.get("llm_vision_escalate_model_gemini") || "",
         llm_vision_escalate_model_ollama: Settings.get("llm_vision_escalate_model_ollama") || "",
         # Stronger text model used only to recheck a refusal on a question the
         # cheap classifier judged answerable by combining stated rules (the
         # multi-hop miss). Blank = reuse the answering model above.
         llm_escalate_model_openrouter: Settings.get("llm_escalate_model_openrouter") || "",
         llm_escalate_model_groq: Settings.get("llm_escalate_model_groq") || "",
         llm_escalate_model_gemini: Settings.get("llm_escalate_model_gemini") || "",
         llm_escalate_model_ollama: Settings.get("llm_escalate_model_ollama") || "",
         # Rulebook extraction mode: "vision" (transcribe every page image — highest
         # accuracy) or "ocr" (pdftotext + OCR, vision only on junk pages).
         rulebook_extract_mode: Settings.get("rulebook_extract_mode") || "vision"
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("select_provider", %{"llm_provider" => provider}, socket) do
    {:noreply, assign(socket, llm_provider: provider)}
  end

  @impl true
  def handle_event("save", params, socket) do
    fields = %{
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
      "llm_escalate_model_openrouter" => params["llm_escalate_model_openrouter"],
      "llm_escalate_model_groq" => params["llm_escalate_model_groq"],
      "llm_escalate_model_gemini" => params["llm_escalate_model_gemini"],
      "llm_escalate_model_ollama" => params["llm_escalate_model_ollama"],
      "rulebook_extract_mode" => params["rulebook_extract_mode"]
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
         llm_vision_escalate_model_openrouter llm_vision_escalate_model_groq llm_vision_escalate_model_gemini llm_vision_escalate_model_ollama
         llm_escalate_model_openrouter llm_escalate_model_groq llm_escalate_model_gemini llm_escalate_model_ollama),
      fn key ->
        if trim(params[key]) == "", do: Settings.delete(key)
      end
    )

    {:noreply,
     assign(socket,
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
       llm_escalate_model_openrouter: fields["llm_escalate_model_openrouter"] |> trim(),
       llm_escalate_model_groq: fields["llm_escalate_model_groq"] |> trim(),
       llm_escalate_model_gemini: fields["llm_escalate_model_gemini"] |> trim(),
       llm_escalate_model_ollama: fields["llm_escalate_model_ollama"] |> trim(),
       rulebook_extract_mode: fields["rulebook_extract_mode"] |> trim(),
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
      <h1 style="font-size:1.25rem;font-weight:700;margin:0.75rem 0 0.25rem 0">LLM Provider</h1>
      <p style="font-size:0.82rem;color:var(--text-muted);margin-bottom:1.25rem">
        Select which LLM service to use for answering questions and generating content.
      </p>

      <div :if={@saved} class="alert alert-info mb-4">
        Settings saved.
      </div>

      <form phx-submit="save" style="display:flex;flex-direction:column;gap:1.25rem">
        <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1.25rem;background:var(--bg-surface)">
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
                Answer escalation model
                <span style="font-weight:400;color:var(--text-muted)">— stronger re-check when a refusal looks answerable by combining stated rules (multi-hop). Blank = use Answer model</span>
              </label>
              <select
                name="llm_escalate_model_openrouter"
                id="llm_escalate_model_openrouter"
                style="width:100%;border:1px solid var(--border-strong);border-radius:0.375rem;padding:0.5rem 0.75rem;font-size:0.85rem;background:var(--bg);color:var(--text)"
              >
                <option value="" selected={@llm_escalate_model_openrouter == ""}>
                  Use Answer model
                </option>
                <.or_model_options selected={@llm_escalate_model_openrouter} />
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

        <button type="submit" class="btn-primary" style="align-self:flex-start">
          Save Settings
        </button>
      </form>

      <div class="mt-6 pt-4 border-t">
        <.link navigate={~p"/admin/usage"} class="back-link" style="margin-bottom:0">
          View LLM Usage &rarr;
        </.link>
      </div>
    </div>
    """
  end
end
