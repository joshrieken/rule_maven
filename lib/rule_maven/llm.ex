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
  Checks FAQ cache first, falls back to retrieval + LLM on miss.
  """
  def ask(game, question, expansion_ids \\ [], recent_context \\ [], opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    # Step 0: embed the question (used for pool check + FAQ check + logging)
    question_embedding =
      case RuleMaven.Embed.embed(question) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    pool_hit =
      question_embedding &&
        RuleMaven.Games.find_similar_question_in_pool(game.id, question_embedding,
          user_id: user_id
        )

    faq_hit = question_embedding && check_faq_cache(game.id, expansion_ids, question_embedding)

    cond do
      pool_hit ->
        {:ok,
         %{
           answer: pool_hit.answer,
           cited_passage: pool_hit.cited_passage,
           provider: "pool",
           model: "cached",
           faq_hit: false,
           pool_hit: true
         }}

      faq_hit ->
        {:ok,
         %{
           answer: faq_hit.canonical_answer,
           cited_passage: faq_hit.canonical_answer,
           provider: "faq",
           model: "cached",
           faq_hit: true
         }}

      true ->
        call_llm(game, question, expansion_ids, recent_context, question_embedding)
    end
  end

  defp call_llm(game, question, expansion_ids, recent_context, question_embedding) do
    game_ids = [game.id | expansion_ids]
    chunks = RuleMaven.Games.retrieve_chunks_for_games(game_ids, question)
    context = Enum.map_join(chunks, "\n\n---\n\n", fn {_, text} -> text end)
    system_prompt = build_system_prompt(game.name, context, recent_context)
    provider_name = provider()
    model_name = model()

    body = %{
      model: model_name,
      max_tokens: 1024,
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
           provider: provider_name,
           model: model_name,
           question_embedding: question_embedding,
           faq_hit: false,
           followup: llm_result[:followup] || false,
           followups: llm_result[:followups] || []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_faq_cache(game_id, expansion_ids, question_embedding) do
    import Ecto.Query

    threshold =
      case RuleMaven.Settings.get("faq_similarity_threshold") do
        nil -> 0.08
        val -> 1.0 - String.to_float(val)
      end

    game_ids = [game_id | expansion_ids]

    RuleMaven.Repo.one(
      from f in RuleMaven.Faq.FaqEntry,
        where:
          f.game_id in ^game_ids and f.status == "published" and
            not is_nil(f.question_embedding),
        where:
          fragment(
            "cosine_distance(?, ?::vector)",
            f.question_embedding,
            ^Pgvector.new(question_embedding)
          ) <= ^threshold,
        order_by:
          fragment(
            "cosine_distance(?, ?::vector)",
            f.question_embedding,
            ^Pgvector.new(question_embedding)
          ),
        limit: 1
    )
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
      model: model(),
      max_tokens: opts[:max_tokens] || 2048,
      messages: messages
    }

    case do_request(body, 1, operation: "chat_#{context}") do
      {:ok, %{answer: text}} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

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
          log_llm(provider_name, model_name, opts, usage, duration, true, nil)
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
      end

    result
  end

  defp extract_usage(body) do
    case body do
      %{"usage" => %{"prompt_tokens" => p, "completion_tokens" => c, "total_tokens" => t}} ->
        %{prompt: p, completion: c, total: t}

      _ ->
        nil
    end
  end

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

  defp build_system_prompt(game_name, full_text, recent_context) do
    context_block =
      if recent_context != [] do
        pairs =
          Enum.map(recent_context, fn {q, a} -> "Q: #{q}\nA: #{String.slice(a, 0, 200)}" end)

        "\nRECENT CONVERSATION:\n#{Enum.join(pairs, "\n\n")}\n\nUse the above for context — this may be a followup question."
      else
        ""
      end

    """
    You are a board game rules lookup tool. You answer questions about "#{game_name}" using ONLY the rulebook text provided below.
    #{context_block}

    REFUSAL RULES — VIOLATING THESE IS A BUG:
    1. If the rulebook text DOES NOT contain the answer, respond with EXACTLY this phrase and nothing else:
       "The rulebook does not cover this question."
    2. Do NOT infer, extrapolate, or use general board game knowledge.
    3. If the text mentions a topic but does not give a rule for the specific situation asked, that counts as "not covered" — refuse.
    4. Do NOT say "the rulebook is unclear" followed by your best guess. Just refuse.
    5. When refusing, do NOT include any FOLLOWUP, FOLLOWUPS, or CITATION markers. The response is ONLY the refusal phrase.

    CONFLICT RULES:
    5. If two sections of the text give different rules for the same thing, cite BOTH sections and state there is a conflict. Do NOT pick one.
    6. Format for conflicts: "There is a conflict: [Section A says X] and [Section B says Y]." End with ---CITATION--- followed by the conflicting passages.

    CROSS-REFERENCE RULES:
    7. If one section refers to another (e.g. "see Section 4.3"), use that referenced section to answer. Reference chains are valid.

    ANSWER FORMAT:
    - Use markdown for structure: **bold** for headings, bullet lists for steps.
    - Keep answers concise — 1-3 sentences of prose plus optional list.
    - Before the citation, add a FOLLOWUP tag: ---FOLLOWUP: yes--- if this question is a followup to the recent conversation (references prior exchange, uses pronouns like "it"/"that"/"they"), otherwise ---FOLLOWUP: no---.
    - ALWAYS suggest 2-3 natural followup questions a player might ask next. Format: ---FOLLOWUPS--- each on its own line, no numbers. Do NOT skip this section.
    - End with ---CITATION--- followed by the exact sentence(s) from the rulebook that support the answer. Include any [Page N] markers from the rulebook text — these indicate the page number.
    - Never fabricate a citation.

    RULEBOOK:
    #{full_text}
    """
  end

  defp parse_response(body) do
    case body do
      %{"choices" => [%{"message" => %{"content" => text}} | _]} ->
        {answer, passage, followup?, followups} = extract_passage(text)

        {:ok,
         %{answer: answer, cited_passage: passage, followup: followup?, followups: followups}}

      %{"error" => %{"message" => message}} ->
        {:error, message}

      _ ->
        {:error, "Unexpected API response format"}
    end
  end

  defp extract_passage(text) do
    # Extract FOLLOWUP tag
    {followup?, cleaned} =
      case Regex.run(~r{---FOLLOWUP:\s*(yes|no)---}i, text) do
        [_, "yes"] -> {true, String.replace(text, ~r{---FOLLOWUP:\s*yes---\s*}i, "")}
        [_, "no"] -> {false, String.replace(text, ~r{---FOLLOWUP:\s*no---\s*}i, "")}
        nil -> {false, text}
      end

    # Extract FOLLOWUPS
    {followups, cleaned} =
      case Regex.run(~r{---FOLLOWUPS---\s*\n(.*?)(?=\n?---CITATION---|$)}s, cleaned) do
        [_, qs] ->
          q_list =
            qs
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(&String.replace(&1, ~r/^(\d+[\.\)]\s*|[-*]\s*)/, ""))

          {q_list,
           String.replace(cleaned, ~r{---FOLLOWUPS---\s*\n.*?(?=\n?---CITATION---|$)}s, "")}

        nil ->
          {[], cleaned}
      end

    case String.split(cleaned, ~r{---CITATION---|---PASSAGE---}, parts: 2) do
      [answer, passage] ->
        answer = answer |> String.trim() |> String.replace(~r/---FOLLOWUPS?.*/s, "")
        {answer, String.trim(passage), followup?, followups}

      _ ->
        {strip_markers(cleaned), nil, followup?, followups}
    end
  end

  defp strip_markers(text) do
    text
    |> String.replace(~r/^---\s*$/ms, "")
    |> String.trim()
  end

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

  def model do
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
        n when is_float(n) -> trunc(n)
        n -> n
      end

    %{
      days: days,
      total_requests: total_requests,
      total_tokens: total_tokens,
      error_count: error_count,
      avg_duration_ms: avg_duration && trunc(avg_duration),
      by_provider: by_provider,
      by_operation: by_operation
    }
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

    prompt = """
    Based on the rulebook text below for "#{game_name}", suggest common rules questions grouped by topic category.
    #{exclude}

    Return in this exact format — each category on its own line, then questions indented with "- ":

    CATEGORY: Setup
    - How many cards do I draw?
    - Who goes first?
    CATEGORY: Combat
    - How does attacking work?
    CATEGORY: Movement
    - How far can I move?

    RULEBOOK (summary):
    #{String.slice(rulebook_text, 0, 3000)}
    """

    case chat(prompt, "suggest_questions",
           system:
             "You generate categorized board game rules questions. Group by topic. Be specific.",
           max_tokens: 512
         ) do
      {:ok, text} ->
        categories =
          text
          |> String.split(~r/^CATEGORY:\s*/mi)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn block ->
            [name | questions] =
              String.split(block, "\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

            questions = Enum.map(questions, &String.replace(&1, ~r/^[-*]\s*/, ""))
            %{category: name, questions: questions}
          end)
          |> Enum.reject(fn %{questions: qs} -> qs == [] end)

        {:ok, categories}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_key do
    provider = RuleMaven.Settings.get("llm_provider") || "openrouter"

    RuleMaven.Settings.get("llm_api_key_#{provider}") || RuleMaven.Settings.get("llm_api_key") ||
      ""
  end
end
