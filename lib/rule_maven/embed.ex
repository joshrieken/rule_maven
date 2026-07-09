defmodule RuleMaven.Embed do
  @moduledoc """
  Generates embeddings via OpenRouter (or other OpenAI-compatible
  embeddings endpoint). Configured via DB settings.
  """

  @default_model "openai/text-embedding-3-small"

  # Stored vectors and the pgvector columns are fixed at this dimension. Switching
  # the embedding model to one that emits a different dimension corrupts similarity
  # search against existing rows, so the dimension is pinned and validated here.
  # See OQ1 in DESIGN.md: changing dimension after data exists is unsupported.
  @expected_dim 768

  def embed(text) when is_binary(text) do
    case Application.get_env(:rule_maven, :embed_mock) do
      # The cache wraps the real API call only. A mock exists precisely to avoid
      # that call, so caching it buys nothing — and the ETS table outlives a
      # single test, so a cached mock vector would leak into the next test that
      # embeds the same text behind a different mock.
      nil -> cached_embed(text)
      mock when is_function(mock) -> mock.(text)
    end
  end

  defp cached_embed(text) do
    # `embedding_model` is a live setting, so the vector a text maps to is only
    # stable per model — the cache key has to carry it.
    model = model()

    case RuleMaven.Embed.Cache.get(model, text) do
      {:ok, vec} ->
        {:ok, vec}

      :miss ->
        text
        |> embed_real()
        |> tap(fn
          {:ok, vec} -> RuleMaven.Embed.Cache.put(model, text, vec)
          {:error, _} -> :ok
        end)
    end
  end

  defp embed_real(text) do
    embed_batch([text])
    |> case do
      {:ok, [vec]} -> {:ok, vec}
      {:error, _} = err -> err
    end
  end

  def embed_batch(texts) when is_list(texts) do
    model = model()
    url = RuleMaven.LLMProxy.embed_url() || api_url()
    key = api_key()

    body = %{
      model: model,
      input: texts,
      dimensions: @expected_dim
    }

    headers =
      [{"Content-Type", "application/json"}] ++
        if key != "" do
          [{"Authorization", "Bearer #{key}"}]
        else
          []
        end

    start = System.monotonic_time(:millisecond)

    {result, usage} =
      case Req.post(url,
             json: body,
             headers: headers,
             receive_timeout: 15_000,
             connect_options: [timeout: 10_000]
           ) do
        {:ok, %{status: 200, body: %{"data" => data} = resp_body}} ->
          vectors =
            data
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          case Enum.find(vectors, &(length(&1) != @expected_dim)) do
            nil ->
              {{:ok, vectors}, resp_body["usage"]}

            bad ->
              {{:error,
                "Embedding dimension mismatch: model #{model} returned #{length(bad)} dims, " <>
                  "expected #{@expected_dim}. Stored vectors are #{@expected_dim}-dim — " <>
                  "switching embedding model is unsupported once data exists."}, nil}
          end

        {:ok, %{status: status, body: resp_body}} ->
          {{:error, "Embedding API returned status #{status}: #{inspect(resp_body)}"}, nil}

        {:error, %{reason: reason}} ->
          {{:error, "Embedding HTTP error: #{inspect(reason)}"}, nil}
      end

    log_question_embed(result, usage, model, System.monotonic_time(:millisecond) - start)
    result
  end

  # Question-path embeds get an llm_logs row so the admin LLM-trace panel shows
  # the full process behind an answer. Gated on the per-process question id
  # (set by AskWorker) — bulk chunk embedding during ingest stays unlogged,
  # otherwise it would flood llm_logs with one row per batch.
  defp log_question_embed(result, usage, model, duration_ms) do
    if question_log_id = RuleMaven.LLM.current_question_log_id() do
      {success, error} =
        case result do
          {:ok, _} -> {true, nil}
          {:error, reason} -> {false, to_string(reason)}
        end

      %RuleMaven.LLM.Log{}
      |> RuleMaven.LLM.Log.changeset(%{
        provider: provider(),
        model: model,
        operation: "embed",
        prompt_tokens: usage && usage["prompt_tokens"],
        total_tokens: usage && usage["total_tokens"],
        duration_ms: duration_ms,
        success: success,
        error_message: error,
        question_log_id: question_log_id
      })
      |> RuleMaven.Repo.insert()
    end

    :ok
  end

  defp provider do
    RuleMaven.Settings.get("embedding_provider") || "openrouter"
  end

  defp model do
    RuleMaven.Settings.get("embedding_model") || @default_model
  end

  defp api_url do
    case provider() do
      "openrouter" ->
        "https://openrouter.ai/api/v1/embeddings"

      "ollama" ->
        "http://localhost:11434/api/embeddings"

      other ->
        RuleMaven.Settings.get("embedding_api_url_#{other}") ||
          "https://openrouter.ai/api/v1/embeddings"
    end
  end

  defp api_key do
    provider_name = provider()

    RuleMaven.Settings.get("embedding_api_key_#{provider_name}") ||
      RuleMaven.Settings.get("llm_api_key_#{provider_name}") ||
      RuleMaven.Settings.get("llm_api_key") ||
      ""
  end
end
