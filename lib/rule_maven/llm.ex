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
  def ask(game, question) do
    # Step 0: embed the question (used for FAQ check + logging)
    question_embedding =
      case RuleMaven.Embed.embed(question) do
        {:ok, vec} -> vec
        {:error, _} -> nil
      end

    # Step 1: check FAQ cache
    faq_hit =
      if question_embedding do
        check_faq_cache(game.id, question_embedding)
      end

    if faq_hit do
      # Instant FAQ answer — no LLM call
      {:ok,
       %{
         answer: faq_hit.canonical_answer,
         cited_passage: faq_hit.canonical_answer,
         provider: "faq",
         model: "cached",
         faq_hit: true
       }}
    else
      # Step 2: retrieve chunks + call LLM
      chunks = RuleMaven.Games.retrieve_chunks(game, question)
      context = Enum.map_join(chunks, "\n\n---\n\n", fn {_, text} -> text end)
      system_prompt = build_system_prompt(game.name, context)
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
        {:ok, %{answer: answer, cited_passage: passage}} ->
          {:ok,
           %{
             answer: answer,
             cited_passage: passage,
             provider: provider_name,
             model: model_name,
             question_embedding: question_embedding,
             faq_hit: false
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_faq_cache(game_id, question_embedding) do
    import Ecto.Query

    threshold =
      case RuleMaven.Settings.get("faq_similarity_threshold") do
        nil -> 0.08
        val -> 1.0 - String.to_float(val)
      end

    RuleMaven.Repo.one(
      from f in RuleMaven.Faq.FaqEntry,
        where:
          f.game_id == ^game_id and f.status == "published" and
            not is_nil(f.question_embedding),
        where:
          fragment(
            "cosine_distance(?, ?::vector)",
            f.question_embedding,
            ^Pgvector.new(question_embedding)
          ) <= ^threshold,
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
    key = api_key()
    url = api_url()
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

  defp build_system_prompt(game_name, full_text) do
    """
    You have ONE job: answer questions about "#{game_name}" using ONLY the rulebook text below.

    CRITICAL — FAILURE MEANS WRONG ANSWER:
    - If the answer is NOT in the text, say exactly: "The rulebook does not cover this question." Do NOT say anything else.
    - Do NOT use your own knowledge about this game.
    - Do NOT explain general gaming concepts.
    - Do NOT guess.

    Answer format:
    1. Direct answer in 1-3 plain sentences.
    2. End with ---CITATION--- followed by the exact sentence from the rulebook.

    RULEBOOK:
    #{full_text}
    """
  end

  defp parse_response(body) do
    case body do
      %{"choices" => [%{"message" => %{"content" => text}} | _]} ->
        {answer, passage} = extract_passage(text)
        {:ok, %{answer: answer, cited_passage: passage}}

      %{"error" => %{"message" => message}} ->
        {:error, message}

      _ ->
        {:error, "Unexpected API response format"}
    end
  end

  defp extract_passage(text) do
    case String.split(text, ~r{---CITATION---|---PASSAGE---}, parts: 2) do
      [answer, passage] -> {String.trim(answer), String.trim(passage)}
      _ -> {text, nil}
    end
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

  defp api_key do
    provider = RuleMaven.Settings.get("llm_provider") || "openrouter"

    RuleMaven.Settings.get("llm_api_key_#{provider}") || RuleMaven.Settings.get("llm_api_key") ||
      ""
  end
end
