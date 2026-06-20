defmodule RuleMaven.Embed do
  @moduledoc """
  Generates embeddings via OpenRouter (or other OpenAI-compatible
  embeddings endpoint). Configured via DB settings.
  """

  @default_model "openai/text-embedding-3-small"

  def embed(text) when is_binary(text) do
    embed_batch([text])
    |> case do
      {:ok, [vec]} -> {:ok, vec}
      {:error, _} = err -> err
    end
  end

  def embed_batch(texts) when is_list(texts) do
    model = model()
    url = api_url()
    key = api_key()

    body = %{
      model: model,
      input: texts
    }

    headers =
      [{"Content-Type", "application/json"}] ++
        if key != "" do
          [{"Authorization", "Bearer #{key}"}]
        else
          []
        end

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Embedding API returned status #{status}: #{inspect(resp_body)}"}

      {:error, %{reason: reason}} ->
        {:error, "Embedding HTTP error: #{inspect(reason)}"}
    end
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
