defmodule RuleMaven.LLM do
  @moduledoc """
  Handles communication with the LLM API via OpenAI-compatible chat completions
  endpoint. Supports multiple providers: Groq, Google Gemini, Ollama, etc.
  Configure via Settings page or env vars.
  """

  @default_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "google/gemini-2.5-flash"

  @providers %{
    "openrouter" => %{
      url: "https://openrouter.ai/api/v1/chat/completions",
      model: "google/gemini-2.5-flash"
    },
    "groq" => %{
      url: "https://api.groq.com/openai/v1/chat/completions",
      model: "llama-3.3-70b-versatile"
    },
    "gemini" => %{
      url: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      model: "gemini-2.5-flash"
    },
    "ollama" => %{
      url: "http://localhost:11434/v1/chat/completions",
      model: "mistral"
    }
  }

  @doc """
  Asks a rules question about a game and returns the answer with cited passage.
  Checks the community pool (curated/promoted Q&A) first; on miss, retrieves
  rulebook chunks and calls the LLM (JSON output).
  """
  def ask(game, question, expansion_ids \\ [], recent_context \\ [], opts \\ []) do
    skip_pool = Keyword.get(opts, :skip_pool, false)

    # Step 0: normalize the question to a standalone canonical form FIRST, then
    # drive everything downstream off the cleaned text. Paraphrases and terse
    # fragments ("snack bar max limit") collapse onto one phrasing, so they share
    # an embedding — lifting the pool hit rate — and the retrieval + LLM answer
    # also run on the cleaned question. Falls back to the raw question on error.
    cleaned = normalize_question(game, question, recent_context)
    match_text = if cleaned == "", do: question, else: cleaned

    # Embed the cleaned question (used for pool check + stored on the logged row,
    # so a future paraphrase normalizes to the same form and matches it).
    question_embedding =
      case RuleMaven.Embed.embed(match_text) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    user_id = opts[:user_id]

    # Pooled/community answers are rulebook-derived, so any asker may be served a
    # match — the lookup intentionally doesn't filter by user (no user_id passed).
    pool_hit =
      !skip_pool && question_embedding &&
        RuleMaven.Games.find_similar_question_in_pool(game.id, question_embedding)

    # Same-user tiers: a returning asker is served their OWN prior answer even
    # when it never pooled. Exact (normalized-text) dedup first, then a tight
    # semantic fallback. Skipped when there's no signed-in asker or skip_pool.
    user_exact =
      !skip_pool && user_id &&
        RuleMaven.Games.find_user_duplicate(game.id, user_id, match_text, question)

    user_semantic =
      !skip_pool && user_id && question_embedding &&
        RuleMaven.Games.find_user_similar(game.id, user_id, question_embedding)

    cond do
      # The asker's OWN exact (normalized-text) repeat wins over the pool lookup:
      # the pool match is user-agnostic, so once the asker's row is pooled a plain
      # pool_hit would tag it same_user_hit=false and AskWorker would copy it into
      # a second row instead of redirecting. Check own-exact first so a repeat
      # always collapses to the one existing Q&A.
      user_exact ->
        serve_from_cache(user_exact, question_embedding, cleaned, game.id, user_id, true)

      pool_hit ->
        serve_from_cache(pool_hit, question_embedding, cleaned, game.id, user_id, false)

      user_semantic ->
        serve_from_cache(user_semantic, question_embedding, cleaned, game.id, user_id, true)

      true ->
        call_llm(game, match_text, expansion_ids, recent_context, question_embedding, cleaned)
    end
  end

  # Builds the cache-serving result from a `{row, tier}` and records the save.
  # Serves answer text only — never the source row's question wording or author.
  # `same_user?` marks a hit on the asker's OWN prior row, so AskWorker can drop
  # the provisional row and redirect to the source instead of copying it.
  defp serve_from_cache({row, tier}, question_embedding, cleaned, game_id, user_id, same_user?) do
    RuleMaven.LLM.Savings.record_cache_hit("ask", game_id, user_id)

    {:ok,
     %{
       answer: row.canonical_answer || row.answer,
       cited_passage: row.cited_passage,
       cited_page: row.cited_page,
       verdict: row.verdict,
       provider: "pool",
       # Encode tier in the model field so it survives a page reload.
       model: if(tier == :trusted, do: "cached", else: "cached-unverified"),
       pool_hit: true,
       same_user_hit: same_user?,
       tier: tier,
       verified: tier == :trusted,
       source_question_log_id: row.id,
       question_embedding: question_embedding,
       cleaned_question: cleaned
     }}
  end

  defp call_llm(game, question, expansion_ids, recent_context, question_embedding, cleaned) do
    game_ids = [game.id | expansion_ids]
    # Reuse the embedding already computed in ask/5 — no second embed call.
    retrieval_opts = if question_embedding, do: [embedding: question_embedding], else: []
    chunks = RuleMaven.Games.retrieve_chunks_for_games(game_ids, question, retrieval_opts)
    context = Enum.map_join(chunks, "\n\n---\n\n", fn {_, text} -> text end)
    system_prompt = build_system_prompt(game.name, game.category, context, recent_context)
    provider_name = provider()
    model_name = model()

    body = %{
      model: model_name,
      max_tokens: 1024,
      response_format: %{type: "json_object"},
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: question}
      ]
    }

    case do_request(body, 1, operation: "ask", game_id: game.id) do
      {:ok, %{answer: answer, cited_passage: passage} = llm_result} ->
        {:ok,
         %{
           answer: answer,
           cited_passage: passage,
           cited_page: llm_result[:cited_page],
           verdict: llm_result[:verdict],
           provider: provider_name,
           model: model_name,
           question_embedding: question_embedding,
           faq_hit: false,
           followups: llm_result[:followups] || [],
           also_asked: llm_result[:also_asked] || [],
           # Canonical question came from the pre-answer normalize step, not the
           # answer JSON — the answer schema no longer carries it.
           cleaned_question: cleaned,
           raw_response: llm_result[:raw_response],
           # Retrieved chunk texts (each prefixed with a [Page N] marker) so the
           # worker can recover the page if the model drops it from the citation.
           source_chunks: Enum.map(chunks, fn {_, text} -> text end)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rewrites a raw user question into a standalone canonical form before it drives
  the pool lookup, retrieval, and the answer. Paraphrases and terse fragments
  converge on one phrasing so they share an embedding and hit the same cached
  answer. Returns the cleaned question, or the original on any error/empty result.

  Uses the cheap cleanup model. Context-free questions are cached per
  `{game_id, raw}`; followups (which carry `recent_context`) are not pure
  functions of the raw text, so they skip the cache.
  """
  def normalize_question(game, question, recent_context \\ []) do
    raw = question |> to_string() |> String.trim()

    # A literally identical re-ask is NOT a followup — normalize it standalone so
    # it collapses onto the original's canonical form + embedding (and hits the
    # cache) instead of being rewritten against the conversation.
    repeat? =
      Enum.any?(recent_context, fn {q, _a} ->
        String.downcase(String.trim(to_string(q))) == String.downcase(raw)
      end)

    cond do
      raw == "" ->
        raw

      # Followups resolve against the conversation — not cacheable by raw text.
      recent_context != [] and not repeat? ->
        do_normalize(game, raw, recent_context)

      true ->
        key = {game.id, String.downcase(raw)}

        case RuleMaven.LLM.NormalizeCache.get(key) do
          {:ok, cached} ->
            cached

          :miss ->
            cleaned = do_normalize(game, raw, [])
            RuleMaven.LLM.NormalizeCache.put(key, cleaned)
            cleaned
        end
    end
  end

  defp do_normalize(game, raw, recent_context) do
    user =
      RuleMaven.Prompts.render("normalize_question", %{
        game_name: game.name,
        game_kind: RuleMaven.Games.Category.context_noun(game.category),
        context_block: normalize_context_block(recent_context),
        question: raw
      })

    case chat(user, "normalize_question",
           system: RuleMaven.Prompts.template("normalize_question_system"),
           max_tokens: 64,
           model: model(:cheap),
           operation: "normalize",
           game_id: game.id
         ) do
      {:ok, text} ->
        cleaned =
          text
          |> to_string()
          |> String.split("\n", parts: 2)
          |> hd()
          |> String.trim()
          |> strip_wrapping_quotes()
          |> strip_game_name(game.name)
          |> String.trim()

        if accept_normalized?(cleaned, raw), do: cleaned, else: raw

      {:error, _} ->
        raw
    end
  end

  # A rewrite is kept only if it's a plausible question (non-empty, not absurdly
  # long): a model that dumped an answer or refusal here is discarded for the raw.
  defp accept_normalized?(cleaned, raw) do
    cleaned != "" and String.length(cleaned) <= 200 and
      String.length(cleaned) <= max(String.length(raw) * 3, 80)
  end

  defp normalize_context_block([]), do: ""

  defp normalize_context_block(recent_context) do
    pairs =
      Enum.map(recent_context, fn {q, a} -> "Q: #{q}\nA: #{String.slice(a, 0, 200)}" end)

    "\nRECENT CONVERSATION:\n#{Enum.join(pairs, "\n\n")}\n"
  end

  # Strip a single pair of wrapping quotes the model sometimes adds.
  defp strip_wrapping_quotes(text) do
    case Regex.run(~r/^["'“”](.*)["'“”]$/u, text) do
      [_, inner] -> inner
      _ -> text
    end
  end

  # Drop the game name if the model echoed it despite the instruction not to,
  # so the canonical form stays game-agnostic (matches the answer-schema rule).
  defp strip_game_name(text, nil), do: text

  defp strip_game_name(text, game_name) do
    text
    |> String.replace(~r/\b#{Regex.escape(game_name)}\b/i, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  # Cleanup prompts are editable templates (Light/Standard/Aggressive). See
  # RuleMaven.Prompts for the defaults.
  defp cleanup_system(:standard), do: RuleMaven.Prompts.template("cleanup_standard")
  defp cleanup_system(:aggressive), do: RuleMaven.Prompts.template("cleanup_aggressive")
  defp cleanup_system(_light), do: RuleMaven.Prompts.template("cleanup_light")

  # The printed page number is stored separately, so it must not stay in the
  # body. Deterministic stripping handles isolated footer lines; this catches
  # the cases OCR glued onto surrounding text.
  defp page_number_hint(n) when is_integer(n) do
    "\n\nThis page's printed page number is #{n}. Remove it where it appears as " <>
      "a standalone header or footer (it is stored separately). NEVER remove a " <>
      "number that is part of a sentence, rule, count, or step."
  end

  defp page_number_hint(_), do: ""

  @doc """
  Cleans a single page of extracted rulebook text via the LLM, fixing
  OCR/extraction artifacts while preserving the wording verbatim (so the Q&A
  flow can still quote it). Returns `{:ok, text, status}` or `{:error, reason}`,
  where `status` is `:cleaned` (model output kept), `:kept_raw` (output rejected
  by the drop guard, raw page returned), or `:empty` (blank input).

  Empty/whitespace input is returned unchanged. If the model returns an empty
  result or drops more characters than the level allows (a likely
  truncation/refusal), the original page is kept instead.

  The drop guard is level-aware: light/standard are near-verbatim, so a >50%
  shrink signals a problem and the raw page is kept. Aggressive deliberately
  strips headers/footers/diagram clutter and reflows badly-scanned pages, so a
  large shrink is expected — it only reverts on a near-total wipe (likely a
  refusal), keeping anything above ~15% of the input.
  """
  def cleanup_page(page_text, level \\ :light, page_number \\ nil, opts \\ []) do
    if String.trim(page_text) == "" do
      {:ok, page_text, :empty}
    else
      case chat(page_text, "cleanup_rulebook",
             system: cleanup_system(level) <> page_number_hint(page_number),
             max_tokens: 4096,
             model: model(:cleanup),
             operation: "cleanup",
             game_id: opts[:game_id]
           ) do
        {:ok, cleaned} ->
          trimmed = String.trim(cleaned)
          min_keep = round(String.length(page_text) * min_kept_ratio(level))

          # Output collapsed below the length floor → treat as a truncation/refusal
          # and keep the raw page. Report `:kept_raw` so the caller can surface
          # that the cleaner was rejected (otherwise it looks identical to a real
          # clean — the page is silently left as its raw extraction).
          if trimmed == "" or String.length(trimmed) < min_keep do
            {:ok, page_text, :kept_raw}
          else
            {:ok, cleaned, :cleaned}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Adversarial check that a page's cleanup preserved its rule content. Given the
  raw extraction and the cleaned text, returns `{:ok, defects}` where `defects`
  is a list of concrete defect lines (empty = faithful), or `{:error, reason}`.
  Uses the cleanup model by default (text-only, cheap). Callers treat an error as
  "no defects" — a critic failure must never block or revert a cleanup.
  """
  def critique_cleanup(raw, cleaned, opts \\ []) do
    user =
      "RAW EXTRACTION:\n\n" <> (raw || "") <> "\n\n---\n\nCLEANED VERSION:\n\n" <> (cleaned || "")

    case chat(user, "cleanup_critic",
           system: RuleMaven.Prompts.template("cleanup_critic"),
           max_tokens: 1024,
           model: opts[:model] || model(:cleanup),
           operation: "cleanup",
           game_id: opts[:game_id]
         ) do
      {:ok, text} -> {:ok, parse_defects(text)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Smallest fraction of the input the cleaned result may shrink to before we
  # treat it as a truncation/refusal and keep the raw page. Aggressive is meant
  # to cut hard, so it tolerates a much larger drop than the verbatim levels.
  defp min_kept_ratio(:aggressive), do: 0.15
  defp min_kept_ratio(_), do: 0.5

  @doc """
  Transcribes a single rulebook page image (PNG/JPEG path) to text via the
  vision model, for pages OCR mangled. Sends the image inline (base64 data URL)
  in an OpenAI-style multimodal message — works with OpenRouter/Gemini, the
  default provider. Returns `{:ok, text}` or `{:error, reason}`.

  Uses the vision model by default — `llm_vision_model_<provider>` if set, else
  the provider's default model (gemini-2.5-flash on OpenRouter is multimodal).
  Deliberately NOT the cleanup model, which is often a text-only model
  (e.g. deepseek). Pass `:model` to override. The caller falls back to the OCR
  text on error, so a non-vision model simply yields `{:error, _}` and no harm.
  """
  def transcribe_page_image(image_path, opts \\ []) do
    case File.read(image_path) do
      {:ok, bin} ->
        mime = if String.ends_with?(image_path, ".jpg"), do: "image/jpeg", else: "image/png"
        data_url = "data:#{mime};base64," <> Base.encode64(bin)

        # Optional guidance appended on a re-read: the adversarial critic's defect
        # list, so the model fixes specific misses rather than re-transcribing blind.
        base_prompt = RuleMaven.Prompts.template("vision_transcribe")

        prompt =
          case opts[:guidance] do
            g when is_binary(g) and g != "" ->
              base_prompt <>
                "\n\nA previous transcription had these defects — fix them this time:\n" <> g

            _ ->
              base_prompt
          end

        messages = [
          %{
            role: "user",
            content: [
              %{type: "text", text: prompt},
              %{type: "image_url", image_url: %{url: data_url}}
            ]
          }
        ]

        body =
          %{
            model: opts[:model] || vision_model(),
            max_tokens: opts[:max_tokens] || 4096,
            messages: messages
          }
          |> maybe_reasoning(opts[:reasoning_effort])

        case do_request(body, 1, operation: "ocr_vision", game_id: opts[:game_id]) do
          {:ok, %{answer: text}} -> {:ok, text}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, "could not read page image: #{inspect(reason)}"}
    end
  end

  # Caps reasoning spend on models that think by default (e.g. Gemini 3 Pro):
  # page transcription is perception, not reasoning — thinking tokens bill at
  # output rate and buy no transcription accuracy. OpenRouter-only knob (other
  # OpenAI-compatible endpoints may reject the unknown key).
  defp maybe_reasoning(body, effort) when effort in ["low", "medium", "high"] do
    if provider() == "openrouter", do: Map.put(body, :reasoning, %{effort: effort}), else: body
  end

  defp maybe_reasoning(body, _), do: body

  @doc """
  Adversarial critic for a page transcription. Given the page image and a
  candidate transcription, returns `{:ok, defects}` where `defects` is a list of
  concrete defect lines (empty list = faithful). `{:error, reason}` on failure
  (caller treats that as "no defects found" — never block on a critic failure).
  Uses the escalation vision model by default (strong, multimodal).
  """
  def critique_page(image_path, transcription, opts \\ []) do
    case File.read(image_path) do
      {:ok, bin} ->
        mime = if String.ends_with?(image_path, ".jpg"), do: "image/jpeg", else: "image/png"
        data_url = "data:#{mime};base64," <> Base.encode64(bin)

        messages = [
          %{
            role: "user",
            content: [
              %{type: "text", text: RuleMaven.Prompts.template("vision_critic")},
              %{type: "image_url", image_url: %{url: data_url}},
              %{type: "text", text: "TRANSCRIPTION TO CHECK:\n\n" <> (transcription || "")}
            ]
          }
        ]

        body = %{
          model: opts[:model] || vision_model(:escalate),
          max_tokens: opts[:max_tokens] || 2048,
          messages: messages
        }

        case do_request(body, 1, operation: "ocr_critic", game_id: opts[:game_id]) do
          {:ok, %{answer: text}} -> {:ok, parse_defects(text)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, "could not read page image: #{inspect(reason)}"}
    end
  end

  @doc """
  Parses an adversarial critic reply into a defect list. A clean page yields `[]`:
  an empty reply, a bare "NONE" (any case, trailing punctuation tolerated), or a
  single-line "no defects/issues/errors" phrasing. Otherwise each non-blank,
  non-"NONE" line is a defect. Tolerant on purpose — a stray period must not be
  read as a defect and trigger a needless (paid) re-transcribe.
  """
  def parse_defects(text) do
    trimmed = String.trim(text || "")

    lines =
      trimmed
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or none_marker?(&1)))

    cond do
      trimmed == "" ->
        []

      # Whole reply is a single "no defects"-style sentence → clean.
      Regex.match?(~r/^\s*no\b.{0,40}\b(defects?|issues?|errors?)\b/i, trimmed) and
          length(lines) <= 1 ->
        []

      true ->
        lines
    end
  end

  # A line that just says "NONE" (any case, surrounding punctuation/markers).
  defp none_marker?(line) do
    line
    |> String.replace(~r/[^\p{L}]/u, "")
    |> String.upcase()
    |> Kernel.==("NONE")
  end

  @doc """
  Sends a generic chat prompt to the LLM. Returns `{:ok, raw_text}` or `{:error, reason}`.
  Options: :max_tokens (default 2048), :system (system prompt string)
  """
  def chat(prompt, context, opts \\ []) do
    messages =
      if system = opts[:system] do
        [%{role: "system", content: system}, %{role: "user", content: prompt}]
      else
        [%{role: "user", content: prompt}]
      end

    body = %{
      model: opts[:model] || model(),
      max_tokens: opts[:max_tokens] || 2048,
      messages: messages
    }

    case do_request(body, 1,
           operation: opts[:operation] || "chat_#{context}",
           game_id: opts[:game_id],
           user_id: opts[:user_id]
         ) do
      {:ok, %{answer: text} = res} ->
        if opts[:reject_truncated] && truncated?(res[:finish_reason], text) do
          {:error, :truncated}
        else
          {:ok, text}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Test seam for the completeness check.
  def __truncated__(finish_reason, text), do: truncated?(finish_reason, text)

  # True when a response was cut off. The provider's finish_reason is
  # authoritative ("length" / "max_tokens"); when it's absent, fall back to a
  # conservative heuristic — text that ends mid-sentence (no terminal
  # punctuation) is treated as incomplete.
  defp truncated?(reason, _text) when reason in ["length", "max_tokens"], do: true
  defp truncated?(nil, text), do: incomplete_text?(text)
  defp truncated?(_reason, _text), do: false

  defp incomplete_text?(text) do
    trimmed = text |> to_string() |> String.trim_trailing()
    trimmed != "" and not Regex.match?(~r/[.!?…)\]"”'`*]$/u, trimmed)
  end

  @doc false
  # Records non-call-avoidance savings from a completed LLM call:
  #   * prompt_cache — real provider discount on cached input tokens
  #   * cheap_route  — counterfactual: ran on the cheap model, not the answer model
  # Best-effort; both may fire for one call.
  def record_call_savings(actual_model, opts, usage) do
    maybe_record_prompt_cache(actual_model, opts, usage)
    maybe_record_cheap_route(actual_model, opts, usage)
    :ok
  end

  defp maybe_record_prompt_cache(actual_model, opts, %{cached: cached}) when is_integer(cached) and cached > 0 do
    require Logger

    try do
      RuleMaven.LLM.Savings.record("prompt_cache", %{
        operation: opts[:operation] || "unknown",
        estimated_tokens: cached,
        estimated_usd: RuleMaven.LLM.Pricing.cached_savings(actual_model, cached),
        model: actual_model,
        game_id: opts[:game_id],
        user_id: opts[:user_id]
      })
    rescue
      e -> Logger.warning("maybe_record_prompt_cache failed: #{inspect(e)}")
    end

    :ok
  end

  defp maybe_record_prompt_cache(_m, _o, _u), do: :ok

  defp maybe_record_cheap_route(actual_model, opts, %{prompt: p, completion: c}) do
    require Logger

    try do
      default = model(:default)

      if actual_model == model(:cheap) and actual_model != default do
        saved = RuleMaven.LLM.Pricing.cost(default, p, c) - RuleMaven.LLM.Pricing.cost(actual_model, p, c)

        RuleMaven.LLM.Savings.record("cheap_route", %{
          operation: opts[:operation] || "unknown",
          estimated_tokens: (p || 0) + (c || 0),
          estimated_usd: max(saved, 0.0),
          model: actual_model,
          game_id: opts[:game_id],
          user_id: opts[:user_id]
        })
      end
    rescue
      e -> Logger.warning("maybe_record_cheap_route failed: #{inspect(e)}")
    end

    :ok
  end

  defp maybe_record_cheap_route(_m, _o, _u), do: :ok

  defp do_request(_body, attempt, _opts) when attempt > 4 do
    {:error, "Rate limited after #{attempt - 1} attempts"}
  end

  defp do_request(body, attempt, opts) do
    # Test-mode mock injection point. Set via Application.put_env(:rule_maven, :llm_mock, fn body -> ... end)
    if mock = Application.get_env(:rule_maven, :llm_mock) do
      mock.(body)
    else
      do_request_real(body, attempt, opts)
    end
  end

  defp do_request_real(body, attempt, opts) do
    key = api_key()
    url = RuleMaven.LLMProxy.chat_url() || api_url()
    model_name = model()
    provider_name = provider()
    start = System.monotonic_time(:millisecond)

    require Logger

    Logger.debug(
      "LLM request: url=#{url} model=#{model_name} has_key=#{key != ""} attempt=#{attempt}"
    )

    headers =
      [{"Content-Type", "application/json"}] ++
        if key != "" do
          [{"Authorization", "Bearer #{key}"}]
        else
          []
        end

    result =
      case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: response_body}} ->
          duration = System.monotonic_time(:millisecond) - start
          usage = extract_usage(response_body)
          actual_model = body[:model] || model_name
          log_llm(provider_name, actual_model, opts, usage, duration, true, nil)
          record_call_savings(actual_model, opts, usage)
          parse_response(response_body)

        {:ok, %{status: 429}} ->
          wait = trunc(:math.pow(2, attempt) * 1000 + :rand.uniform(1000))
          Logger.warning("LLM rate limited (429), retrying in #{wait}ms (attempt #{attempt})")
          Process.sleep(wait)
          do_request(body, attempt + 1, opts)

        {:ok, %{status: status, body: resp_body}} ->
          duration = System.monotonic_time(:millisecond) - start
          error = "API returned status #{status}: #{inspect(resp_body)}"
          log_llm(provider_name, model_name, opts, nil, duration, false, error)
          {:error, error}

        {:error, %{reason: reason}} ->
          duration = System.monotonic_time(:millisecond) - start
          error = "HTTP error: #{inspect(reason)}"
          log_llm(provider_name, model_name, opts, nil, duration, false, error)
          {:error, error}

        # Catch-all for any other Req error shape (exception structs without a
        # :reason key) so an odd transport failure returns {:error, _} instead
        # of raising a CaseClauseError that crashes the caller.
        {:error, other} ->
          duration = System.monotonic_time(:millisecond) - start
          error = "HTTP error: #{inspect(other)}"
          log_llm(provider_name, model_name, opts, nil, duration, false, error)
          {:error, error}
      end

    result
  end

  defp extract_usage(body) do
    case body do
      %{"usage" => %{"prompt_tokens" => p, "completion_tokens" => c, "total_tokens" => t} = u} ->
        %{prompt: p, completion: c, total: t, cached: cached_tokens(u)}

      _ ->
        nil
    end
  end

  # Provider-reported cached prompt tokens, OpenAI-compatible shape OpenRouter
  # forwards. Tolerates the field being absent (other providers) → 0.
  defp cached_tokens(%{"prompt_tokens_details" => %{"cached_tokens" => n}}) when is_integer(n), do: n
  defp cached_tokens(%{"cached_tokens" => n}) when is_integer(n), do: n
  defp cached_tokens(_), do: 0

  defp log_llm(provider, model, opts, usage, duration_ms, success, error) do
    alias RuleMaven.Repo

    %RuleMaven.LLM.Log{}
    |> RuleMaven.LLM.Log.changeset(%{
      provider: provider,
      model: model,
      operation: opts[:operation] || "unknown",
      prompt_tokens: usage && usage[:prompt],
      completion_tokens: usage && usage[:completion],
      total_tokens: usage && usage[:total],
      duration_ms: duration_ms,
      success: success,
      error_message: error,
      game_id: opts[:game_id],
      user_id: opts[:user_id]
    })
    |> Repo.insert()
  end

  defp build_system_prompt(game_name, category, full_text, recent_context) do
    kind = RuleMaven.Games.Category.context_noun(category)

    context_block =
      if recent_context != [] do
        pairs =
          Enum.map(recent_context, fn {q, a} -> "Q: #{q}\nA: #{String.slice(a, 0, 200)}" end)

        "\nRECENT CONVERSATION:\n#{Enum.join(pairs, "\n\n")}\n\nUse the above for context — this may be a followup question."
      else
        ""
      end

    RuleMaven.Prompts.render("answer", %{
      game_name: game_name,
      game_kind: kind,
      context_block: context_block,
      rulebook: full_text
    })
  end

  defp parse_response(body) do
    case body do
      %{"choices" => [%{"message" => %{"content" => content}} = choice | _]} ->
        # finish_reason == "length" (or Anthropic "max_tokens") means the model was
        # cut off at the token cap — surfaced so callers can reject a partial.
        finish_reason = choice["finish_reason"] || body["stop_reason"]

        {:ok,
         content
         |> decode_answer()
         |> Map.put(:raw_response, content)
         |> Map.put(:finish_reason, finish_reason)}

      %{"error" => %{"message" => message}} ->
        {:error, message}

      _ ->
        {:error, "Unexpected API response format"}
    end
  end

  # Decode the model's JSON answer object. Degrades gracefully if the model
  # ignored the JSON instruction: the raw content becomes the answer.
  defp decode_answer(content) do
    # A reasoning model that hits max_tokens mid-thought can return null content;
    # normalize so nothing downstream (Jason.decode, String.trim) crashes on nil.
    content = content || ""

    case json_object(content) do
      {:ok, map} ->
        %{
          answer: trimmed_string(map["answer"]),
          cited_passage: nilable_string(map["citation"]),
          cited_page: coerce_page(map["page"]),
          verdict: coerce_verdict(map["verdict"]),
          followups: string_list(map["followups"]),
          also_asked: string_list(map["also_asked"])
        }

      :error ->
        %{
          answer: String.trim(content),
          cited_passage: nil,
          cited_page: nil,
          verdict: nil,
          followups: [],
          also_asked: []
        }
    end
  end

  # Parse a JSON object, tolerating ```json fences or stray prose around it.
  defp json_object(content) do
    case Jason.decode(content) do
      {:ok, %{} = m} ->
        {:ok, m}

      _ ->
        with [candidate] <- Regex.run(~r/\{.*\}/s, content),
             {:ok, %{} = m} <- Jason.decode(candidate) do
          {:ok, m}
        else
          _ -> :error
        end
    end
  end

  defp trimmed_string(v) when is_binary(v), do: String.trim(v)
  defp trimmed_string(_), do: ""

  defp nilable_string(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp nilable_string(_), do: nil

  defp string_list(v) when is_list(v) do
    v
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_), do: []

  # Page may arrive as an int or a stringified int ("5", "p.5", "Page 5").
  defp coerce_page(n) when is_integer(n) and n > 0, do: n

  defp coerce_page(s) when is_binary(s) do
    case Regex.run(~r/\d+/, s) do
      [num] -> String.to_integer(num)
      _ -> nil
    end
  end

  defp coerce_page(_), do: nil

  # Normalize the model's verdict to the fixed vocabulary; unknown/missing -> nil.
  defp coerce_verdict(v) when is_binary(v) do
    case v |> String.trim() |> String.downcase() do
      "legal" -> "legal"
      "illegal" -> "illegal"
      "silent" -> "silent"
      "info" -> "info"
      _ -> nil
    end
  end

  defp coerce_verdict(_), do: nil

  defp api_url do
    provider_name = provider()
    provider_conf = @providers[provider_name]

    case provider_conf do
      %{url: url} -> url
      _ -> RuleMaven.Settings.get("llm_api_url") || @default_url
    end
  end

  def provider do
    RuleMaven.Settings.get("llm_provider") || "openrouter"
  end

  @doc """
  Model id for a given purpose. `:default` (answering, summaries, etc.) reads the
  per-provider `llm_model_<provider>` override, then the provider default. `:cleanup`
  (rulebook text cleanup) first checks `llm_cleanup_model_<provider>` and falls back
  to the `:default` model when unset — so cleanup can run a cheaper/faster model
  than answering without touching the answering config.
  """
  def model(purpose \\ :default)

  def model(:cleanup) do
    case RuleMaven.Settings.get("llm_cleanup_model_#{provider()}") do
      m when is_binary(m) and m != "" -> m
      _ -> model(:default)
    end
  end

  def model(:cheap) do
    case RuleMaven.Settings.get("llm_cheap_model_#{provider()}") do
      m when is_binary(m) and m != "" -> m
      _ -> model(:cleanup)
    end
  end

  def model(_default) do
    provider_name = provider()
    provider_conf = @providers[provider_name]

    # Check per-provider custom model first
    custom = RuleMaven.Settings.get("llm_model_#{provider_name}")

    cond do
      custom && custom != "" -> custom
      provider_conf -> provider_conf.model
      true -> RuleMaven.Settings.get("llm_model") || @default_model
    end
  end

  @doc """
  The multimodal model used to transcribe rulebook page images. `:default`
  (`llm_vision_model_<provider>`, else the provider default) reads every page;
  `:escalate` (`llm_vision_escalate_model_<provider>`, else the default vision
  model) is a stronger/higher-res model used only to re-read pages the default
  model failed on. Separate from `model(:cleanup)` because the cleanup model is
  frequently a text-only model that can't take image input.
  """
  def vision_model(purpose \\ :default)

  def vision_model(:escalate) do
    case RuleMaven.Settings.get("llm_vision_escalate_model_#{provider()}") do
      m when is_binary(m) and m != "" -> m
      _ -> vision_model(:default)
    end
  end

  # Mid tier — the T2 reader between cheap cross-check and the top-model+critic
  # escalation. Falls back to the escalate model when unset, so an unconfigured
  # install still climbs (just skips straight to the strong read at T2b).
  def vision_model(:mid) do
    case RuleMaven.Settings.get("llm_vision_mid_model_#{provider()}") do
      m when is_binary(m) and m != "" -> m
      _ -> vision_model(:escalate)
    end
  end

  def vision_model(_default) do
    case RuleMaven.Settings.get("llm_vision_model_#{provider()}") do
      m when is_binary(m) and m != "" -> m
      _ -> model(:default)
    end
  end

  @doc """
  Returns usage stats for the last N days.
  """
  def stats(days \\ 30) do
    alias RuleMaven.Repo
    import Ecto.Query

    since = DateTime.add(DateTime.utc_now(), -days, :day)

    base = from(l in RuleMaven.LLM.Log, where: l.inserted_at >= ^since)

    total_requests = Repo.aggregate(base, :count)

    total_tokens =
      case Repo.one(from(l in base, select: sum(l.total_tokens))) do
        nil -> 0
        n -> n
      end

    by_provider =
      Repo.all(
        from(l in base,
          group_by: l.provider,
          select: {l.provider, count(l.id), sum(l.total_tokens)}
        )
      )
      |> Enum.map(fn {p, c, t} -> %{provider: p, requests: c, tokens: t || 0} end)

    by_operation =
      Repo.all(
        from(l in base,
          group_by: l.operation,
          select: {l.operation, count(l.id), sum(l.total_tokens)}
        )
      )
      |> Enum.map(fn {o, c, t} -> %{operation: o, requests: c, tokens: t || 0} end)

    error_count = Repo.aggregate(from(l in base, where: l.success == false), :count)

    avg_duration =
      case Repo.one(from(l in base, select: avg(l.duration_ms))) do
        nil -> nil
        %Decimal{} = n -> n |> Decimal.round() |> Decimal.to_integer()
        n when is_float(n) -> trunc(n)
        n -> n
      end

    %{
      days: days,
      total_requests: total_requests,
      total_tokens: total_tokens,
      error_count: error_count,
      avg_duration_ms: avg_duration,
      by_provider: by_provider,
      by_operation: by_operation
    }
  end

  @doc """
  Per-user LLM cost (USD estimate) over the last N days, highest spend first.
  Costs are derived from logged token counts via `RuleMaven.LLM.Pricing`.
  """
  def cost_by_user(days \\ 30) do
    alias RuleMaven.Repo
    alias RuleMaven.LLM.Pricing
    import Ecto.Query

    since = DateTime.add(DateTime.utc_now(), -days, :day)

    rows =
      Repo.all(
        from l in RuleMaven.LLM.Log,
          where: l.inserted_at >= ^since and not is_nil(l.user_id),
          group_by: [l.user_id, l.model],
          select: {
            l.user_id,
            l.model,
            sum(l.prompt_tokens),
            sum(l.completion_tokens),
            count(l.id)
          }
      )

    names =
      Repo.all(from u in RuleMaven.Users.User, select: {u.id, u.username}) |> Map.new()

    rows
    |> Enum.group_by(fn {uid, _, _, _, _} -> uid end)
    |> Enum.map(fn {uid, model_rows} ->
      {cost, tokens, requests} =
        Enum.reduce(model_rows, {0.0, 0, 0}, fn {_uid, model, p, c, n}, {cost, tok, req} ->
          {cost + Pricing.cost(model, p, c), tok + (p || 0) + (c || 0), req + n}
        end)

      %{
        user_id: uid,
        username: Map.get(names, uid, "#" <> to_string(uid)),
        cost: cost,
        tokens: tokens,
        requests: requests
      }
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  @doc "USD cost estimate of a single user's LLM usage since UTC midnight today."
  def user_cost_today(user_id) when is_integer(user_id) do
    alias RuleMaven.Repo
    alias RuleMaven.LLM.Pricing
    import Ecto.Query

    since = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.all(
      from l in RuleMaven.LLM.Log,
        where: l.user_id == ^user_id and l.inserted_at >= ^since,
        group_by: l.model,
        select: {l.model, sum(l.prompt_tokens), sum(l.completion_tokens)}
    )
    |> Enum.reduce(0.0, fn {model, p, c}, acc -> acc + Pricing.cost(model, p, c) end)
  end

  def user_cost_today(_), do: 0.0

  @doc "USD cost estimate of ALL LLM usage since UTC midnight today (whole app)."
  def cost_today do
    alias RuleMaven.Repo
    alias RuleMaven.LLM.Pricing
    import Ecto.Query

    since = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.all(
      from l in RuleMaven.LLM.Log,
        where: l.inserted_at >= ^since,
        group_by: l.model,
        select: {l.model, sum(l.prompt_tokens), sum(l.completion_tokens)}
    )
    |> Enum.reduce(0.0, fn {model, p, c}, acc -> acc + Pricing.cost(model, p, c) end)
  end

  @doc """
  Per-operation LLM cost (USD estimate) for a single game, highest spend first.
  Each row is `%{operation, requests, prompt_tokens, completion_tokens, cost}`.
  Pass `since` (a `DateTime`) to bound the window. Cost is summed per
  `{operation, model}` so per-row model pricing stays accurate.
  """
  def cost_by_operation_for_game(game_id, since \\ nil) do
    alias RuleMaven.Repo
    alias RuleMaven.LLM.Pricing
    import Ecto.Query

    base = from(l in RuleMaven.LLM.Log, where: l.game_id == ^game_id)
    base = if since, do: from(l in base, where: l.inserted_at >= ^since), else: base

    Repo.all(
      from l in base,
        group_by: [l.operation, l.model],
        select: {
          l.operation,
          l.model,
          sum(l.prompt_tokens),
          sum(l.completion_tokens),
          count(l.id)
        }
    )
    |> Enum.group_by(fn {op, _, _, _, _} -> op end)
    |> Enum.map(fn {op, model_rows} ->
      {cost, p_tok, c_tok, requests} =
        Enum.reduce(model_rows, {0.0, 0, 0, 0}, fn {_op, model, p, c, n}, {cost, pt, ct, req} ->
          {cost + Pricing.cost(model, p, c), pt + (p || 0), ct + (c || 0), req + n}
        end)

      %{
        operation: op,
        requests: requests,
        prompt_tokens: p_tok,
        completion_tokens: c_tok,
        cost: cost
      }
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  @doc """
  Total LLM cost (USD estimate) for a single game across all operations. Pass
  `since` (a `DateTime`) to bound the window.
  """
  def cost_for_game(game_id, since \\ nil) do
    cost_by_operation_for_game(game_id, since)
    |> Enum.reduce(0.0, fn %{cost: c}, acc -> acc + c end)
  end

  @doc """
  Total LLM cost (USD) for one game over a time window, restricted to the given
  `operations`. Used by `Jobs.finish_run/3` to stamp a single job run's spend
  (a pipeline step runs in its own window for its own operation, so this cleanly
  attributes per-run cost). Returns `0.0` when `operations` is empty.
  """
  def cost_in_window(_game_id, [], _from, _to), do: 0.0

  def cost_in_window(game_id, operations, %DateTime{} = from, %DateTime{} = to) do
    alias RuleMaven.Repo
    alias RuleMaven.LLM.Pricing
    import Ecto.Query

    Repo.all(
      from l in RuleMaven.LLM.Log,
        where:
          l.game_id == ^game_id and l.operation in ^operations and
            l.inserted_at >= ^from and l.inserted_at <= ^to,
        group_by: l.model,
        select: {l.model, sum(l.prompt_tokens), sum(l.completion_tokens)}
    )
    |> Enum.reduce(0.0, fn {model, p, c}, acc -> acc + Pricing.cost(model, p, c) end)
  end

  def cost_in_window(_game_id, _operations, _from, _to), do: 0.0

  @doc """
  Error rate over the last `hours` hours: %{requests, errors, rate} where rate
  is a 0.0–1.0 float (0.0 when no requests).
  """
  def error_rate(hours \\ 24) do
    alias RuleMaven.Repo
    import Ecto.Query

    since = DateTime.add(DateTime.utc_now(), -hours, :hour)
    base = from(l in RuleMaven.LLM.Log, where: l.inserted_at >= ^since)

    total = Repo.aggregate(base, :count)
    errors = Repo.aggregate(from(l in base, where: l.success == false), :count)
    rate = if total > 0, do: errors / total, else: 0.0

    %{requests: total, errors: errors, rate: rate}
  end

  @doc """
  Generates a list of suggested questions for a game based on its rulebook text.
  Returns `{:ok, [question_string]}` or `{:error, reason}`.
  """
  def suggest_questions(game_name, rulebook_text, already_asked \\ []) do
    exclude =
      if already_asked != [] do
        "Do NOT suggest any of these already-asked questions: #{Enum.map_join(already_asked, ", ", &"\"#{&1}\"")}"
      else
        ""
      end

    prompt =
      RuleMaven.Prompts.render("suggest_questions", %{
        game_name: game_name,
        exclude: exclude,
        rulebook: String.slice(rulebook_text, 0, 3000)
      })

    case chat(prompt, "suggest_questions",
           system: RuleMaven.Prompts.template("suggest_questions_system"),
           model: model(:cheap),
           operation: "suggest_questions",
           max_tokens: 512
         ) do
      {:ok, text} ->
        # Everything before the first "CATEGORY:" is preamble (e.g. "Here are
        # common questions for X, grouped by category:") — drop it so it never
        # becomes a bogus category name.
        blocks =
          text
          |> String.split(~r/^CATEGORY:\s*/mi)
          |> Enum.drop(1)

        categories =
          if blocks == [] do
            # Model ignored the CATEGORY: format — salvage the "- " questions
            # under a single generic category rather than show the preamble.
            qs = bullet_lines(text)
            if qs == [], do: [], else: [%{category: "Suggested", questions: qs}]
          else
            blocks
            |> Enum.map(fn block ->
              [name | _] =
                String.split(block, "\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

              %{category: name, questions: bullet_lines(block)}
            end)
            |> Enum.reject(fn %{questions: qs} -> qs == [] end)
          end

        {:ok, categories}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates a list of short, standalone "Did you know?" rule facts for a game
  from its rulebook text. Each is a friendly one- or two-sentence nugget — the
  kind worth surfacing on the game's empty state. Returns `{:ok, [fact_string]}`
  or `{:error, reason}`.
  """
  def generate_did_you_know(game_name, rulebook_text, game_id \\ nil) do
    prompt =
      RuleMaven.Prompts.render("did_you_know", %{
        game_name: game_name,
        # Wider sample (≈16k across ~8 coherent windows) so there's enough source
        # material to draw up to ~50 distinct facts from.
        rulebook: sample_across(rulebook_text, 16000, 2000)
      })

    case chat(prompt, "did_you_know",
           model: model(:cheap),
           operation: "did_you_know",
           game_id: game_id,
           system: RuleMaven.Prompts.template("did_you_know_system"),
           # Room for up to ~50 facts plus reasoning-model overhead; too low and
           # the cap is hit mid-thought, returning empty content with no bullets.
           max_tokens: 8000
         ) do
      {:ok, text} ->
        facts =
          text
          |> bullet_lines()
          |> Enum.map(&String.trim/1)
          # Strip any stray "Did you know?" prefix the model adds anyway — the
          # section heading already says it.
          |> Enum.map(&String.replace(&1, ~r/^did you know[:?,!\s-]*/i, ""))
          |> Enum.map(&String.trim/1)
          # Drop blanks and truncated runt fragments (a cut-off final bullet).
          |> Enum.reject(&(String.length(&1) < 20))
          |> Enum.uniq()

        {:ok, verify_did_you_know(game_name, rulebook_text, facts, game_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Second-pass fact-check: drop any generated fact that isn't fully/accurately
  # supported by the rulebook (catches misleading-by-omission paraphrases, e.g.
  # "X is removed" when X is removed then reused). Fail-open — a verify error or
  # unparseable reply keeps the original facts rather than nuking the whole list.
  defp verify_did_you_know(_game_name, _text, [], _game_id), do: []

  defp verify_did_you_know(game_name, rulebook_text, facts, game_id) do
    numbered =
      facts
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {f, i} -> "#{i}. #{f}" end)

    prompt =
      RuleMaven.Prompts.render("did_you_know_verify", %{
        game_name: game_name,
        # Wider sample than generation so the checker is likelier to see the
        # clause a fact may have omitted.
        rulebook: sample_across(rulebook_text, 24000, 3000),
        facts: numbered
      })

    case chat(prompt, "did_you_know_verify",
           model: model(:cheap),
           operation: "did_you_know_verify",
           game_id: game_id,
           system: RuleMaven.Prompts.template("did_you_know_verify_system"),
           max_tokens: 600
         ) do
      {:ok, text} ->
        case parse_keep_indices(text, length(facts)) do
          :all ->
            facts

          keep ->
            facts
            |> Enum.with_index(1)
            |> Enum.filter(fn {_, i} -> MapSet.member?(keep, i) end)
            |> Enum.map(&elem(&1, 0))
        end

      {:error, _} ->
        facts
    end
  end

  @doc """
  Generates a set of in-character persona voices themed to a specific game from
  its rulebook text. Each voice is a tone instruction (never a rule source) the
  restyler later uses to re-voice canonical answers. Returns
  `{:ok, [%{slug, label, emoji, style}]}` (3–6 entries) or `{:error, reason}`.
  The model decides the count; a thin rulebook yields fewer.
  """
  def generate_voices(game_name, rulebook_text) do
    prompt =
      RuleMaven.Prompts.render("generate_voices", %{
        game_name: game_name,
        # A contiguous head excerpt, not sample_across's fragmented "\n...\n"
        # windows: the flash model reliably returns an EMPTY completion for the
        # fragmented input here, while a contiguous excerpt yields a full themed
        # set. Theme/flavor is front-loaded in rulebooks, so the head is enough.
        rulebook: String.slice(rulebook_text, 0, 8000)
      })

    case chat(prompt, "generate_voices",
           system: RuleMaven.Prompts.template("generate_voices_system"),
           # Each voice now carries 4-6 loading_phrases on top of its style, so
           # a full 6-voice set needs noticeably more room. Too low and the JSON
           # truncates mid-array → parse fails → no voices.
           max_tokens: 2600
         ) do
      {:ok, text} ->
        {:ok, parse_voices(text)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Decode the voices JSON array, tolerating ```fences``` and stray prose, then
  # coerce each entry to a clean voice map. Bad/incomplete entries are dropped;
  # slugs are normalized and de-duplicated; the list is capped at 6.
  defp parse_voices(text) do
    json =
      case Regex.run(~r/\[.*\]/s, text || "") do
        [match] -> match
        _ -> text || ""
      end

    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.map(&coerce_voice/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.slug)
        |> Enum.take(6)

      _ ->
        []
    end
  end

  @doc false
  # Test seam for parse_voices/1.
  def __parse_voices__(text), do: parse_voices(text)

  defp coerce_voice(%{"label" => label, "emoji" => emoji, "style" => style} = m)
       when is_binary(label) and is_binary(emoji) and is_binary(style) do
    label = String.trim(label)
    style = String.trim(style)
    slug = m |> Map.get("slug", label) |> to_string() |> slugify()
    loading = m |> Map.get("loading_phrases", []) |> coerce_phrases()

    if label != "" and style != "" and slug != "" do
      %{slug: slug, label: label, emoji: String.trim(emoji), style: style, loading_phrases: loading}
    end
  end

  defp coerce_voice(_), do: nil

  # Keep only non-blank string phrases, trimmed, capped at 6.
  defp coerce_phrases(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
  end

  defp coerce_phrases(_), do: []

  # Stable, namespace-safe slug: lowercase, non-alphanumerics → "-", trimmed.
  defp slugify(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  # Parse the verifier's "1,4,5" / "none" reply into a MapSet of kept indices.
  # Returns :all on an unparseable non-"none" reply (fail-open, never drop all on
  # a glitch); an empty set only when the model explicitly says "none".
  defp parse_keep_indices(text, _count) do
    trimmed = String.trim(text || "")

    cond do
      Regex.match?(~r/^\s*none\b/i, trimmed) ->
        MapSet.new()

      true ->
        nums =
          Regex.scan(~r/\d+/, trimmed)
          |> Enum.map(fn [n] -> String.to_integer(n) end)

        if nums == [], do: :all, else: MapSet.new(nums)
    end
  end

  # Sample `budget` chars from `text` as evenly-spaced windows of ~`window` chars
  # spanning the whole document, so generation sees the start, middle, AND end
  # (where edge-case/advanced rules — the best "Did you know?" material — live)
  # instead of just the intro. Returns the whole text when it fits in budget.
  #
  # Keep `window` reasonably large (≥~2000): many small fragments cut mid-sentence
  # confuse reasoning models into spending their whole token budget "thinking" and
  # returning empty content. Fewer, coherent windows generate reliably.
  defp sample_across(text, budget, window) do
    len = String.length(text)

    if len <= budget do
      text
    else
      count = max(div(budget, window), 1)
      # Last valid start so a window never runs off the end.
      max_start = len - window
      step = if count > 1, do: div(max_start, count - 1), else: 0

      0..(count - 1)
      |> Enum.map(fn i -> String.slice(text, i * step, window) end)
      |> Enum.join("\n...\n")
    end
  end

  # Pull the "- " / "* " bullet lines out of a block as clean question strings,
  # ignoring any prose/preamble lines that aren't bullets.
  defp bullet_lines(block) do
    block
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^[-*]\s+/, &1))
    |> Enum.map(&String.replace(&1, ~r/^[-*]\s*/, ""))
  end

  @doc """
  Generates topic categories for a game based on its rulebook text.
  Returns `{:ok, [%{name: string, description: string}]}` or `{:error, reason}`.
  """
  def generate_categories(game_name, rulebook_text, game_id \\ nil) do
    # Sample: first 1500 + last 1500 + 3 random middle chunks of 500
    len = String.length(rulebook_text)
    front = String.slice(rulebook_text, 0, 1500)
    back = if len > 1500, do: String.slice(rulebook_text, max(len - 1500, 0), 1500), else: ""

    middle_samples =
      if len > 3000 do
        step = div(len - 3000, 4)

        Enum.map([1, 2, 3], fn i ->
          start = 1500 + i * step
          String.slice(rulebook_text, start, 500)
        end)
        |> Enum.join("\n...\n")
      else
        ""
      end

    sample = Enum.reject([front, middle_samples, back], &(&1 == "")) |> Enum.join("\n...\n")

    full_prompt =
      RuleMaven.Prompts.render("categories", %{game_name: game_name, rulebook: sample})

    case chat(full_prompt, "generate_categories",
           operation: "categories",
           game_id: game_id,
           system: RuleMaven.Prompts.template("categories_system"),
           max_tokens: 400
         ) do
      {:ok, text} ->
        cats =
          text
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, desc] -> [%{name: String.trim(name), description: String.trim(desc)}]
              _ -> []
            end
          end)

        {:ok, cats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Designs a per-game color theme from the game's cover art. Returns
  `{:ok, %{"light" => anchors, "dark" => anchors}}` where each anchors map has
  string keys `accent`/`bg`/`surface`/`text` (hex strings) — feed straight into
  `RuleMaven.ThemePalette.build/1`. `{:error, reason}` on fetch/LLM/parse failure.
  """
  def generate_theme_palette(game_name, image_url, game_id \\ nil)

  def generate_theme_palette(game_name, image_url, game_id) when is_binary(image_url) do
    with {:ok, data_url} <- fetch_image_data_url(image_url),
         prompt = RuleMaven.Prompts.render("theme_palette", %{game_name: game_name}),
         messages = [
           %{
             role: "user",
             content: [
               %{type: "text", text: prompt},
               %{type: "image_url", image_url: %{url: data_url}}
             ]
           }
         ],
         body = %{model: vision_model(), max_tokens: 600, messages: messages},
         # Read :raw_response, not :answer — decode_answer/1 assumes the Q&A JSON
         # schema and would extract a nonexistent "answer" key from our palette
         # JSON, yielding "". raw_response is the unparsed model content.
         {:ok, %{raw_response: text}} <-
           do_request(body, 1, operation: "theme_palette", game_id: game_id) do
      parse_theme_anchors(text)
    end
  end

  def generate_theme_palette(_game_name, _, _game_id), do: {:error, :no_image}

  # Pull the cover bytes and inline them as a data URL (BGG URLs can be flaky /
  # hotlink-protected; inlining keeps the vision call self-contained + durable).
  defp fetch_image_data_url(url) do
    case Req.get(url, decode_body: false, max_retries: 2, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: bin, headers: headers}} when is_binary(bin) ->
        mime =
          case headers["content-type"] || headers["Content-Type"] do
            [ct | _] -> ct
            ct when is_binary(ct) -> ct
            _ -> guess_mime(url)
          end
          |> to_string()
          |> String.split(";")
          |> List.first()

        mime =
          if mime in ["image/jpeg", "image/png", "image/webp", "image/gif"],
            do: mime,
            else: guess_mime(url)

        {:ok, "data:#{mime};base64," <> Base.encode64(bin)}

      {:ok, %{status: status}} ->
        {:error, {:image_http, status}}

      {:error, reason} ->
        {:error, {:image_fetch, reason}}
    end
  end

  defp guess_mime(url) do
    cond do
      String.match?(url, ~r/\.png(\?|$)/i) -> "image/png"
      String.match?(url, ~r/\.webp(\?|$)/i) -> "image/webp"
      true -> "image/jpeg"
    end
  end

  # The model is asked for raw JSON; tolerate ```fences``` and surrounding prose
  # by extracting the first {...} block before decoding.
  defp parse_theme_anchors(text) do
    json =
      case Regex.run(~r/\{.*\}/s, text || "") do
        [match] -> match
        _ -> text
      end

    case Jason.decode(json || "") do
      {:ok, %{"light" => l, "dark" => d}} when is_map(l) and is_map(d) ->
        {:ok, %{"light" => l, "dark" => d}}

      {:ok, _} ->
        {:error, :bad_palette_shape}

      {:error, _} ->
        {:error, :palette_parse_failed}
    end
  end

  defp api_key do
    provider = RuleMaven.Settings.get("llm_provider") || "openrouter"

    RuleMaven.Settings.get("llm_api_key_#{provider}") || RuleMaven.Settings.get("llm_api_key") ||
      ""
  end
end
