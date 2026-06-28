defmodule RuleMaven.LLM.Pricing do
  @moduledoc """
  Approximate USD pricing per 1M tokens, used to turn the token counts in
  `llm_logs` into dollar estimates for the cost dashboard and budget cap.

  These are estimates for budgeting/alerting, not billing — provider prices
  change, so update the table as needed. Unknown models fall back to a
  conservative default rate. Matching is by substring so provider-prefixed ids
  ("google/gemini-2.5-flash") and bare ids ("gemini-2.5-flash") both resolve.
  """

  # {input_per_mtok, output_per_mtok} in USD.
  @prices [
    {"gemini-2.5-flash", {0.30, 2.50}},
    {"gemini-2.5-pro", {1.25, 10.00}},
    {"gemini-2.0-flash", {0.10, 0.40}},
    {"gemini-1.5-flash", {0.075, 0.30}},
    {"llama-3.3-70b", {0.59, 0.79}},
    {"llama-3.1-8b", {0.05, 0.08}},
    {"gpt-4o-mini", {0.15, 0.60}},
    {"gpt-4o", {2.50, 10.00}},
    {"text-embedding-3-small", {0.02, 0.0}},
    {"text-embedding-3-large", {0.13, 0.0}}
  ]

  # Used when no entry matches — deliberately not free, so unknown spend is
  # still surfaced rather than hidden as $0.
  @default_rate {0.50, 1.50}

  @doc "USD cost for a single call's prompt/completion token counts."
  def cost(model, prompt_tokens, completion_tokens) do
    {in_rate, out_rate} = rate(model)
    p = (prompt_tokens || 0) / 1_000_000 * in_rate
    c = (completion_tokens || 0) / 1_000_000 * out_rate
    p + c
  end

  @doc "Returns the {input, output} per-1M-token rate for a model (with fallback)."
  def rate(nil), do: @default_rate

  def rate(model) do
    m = String.downcase(model)

    case Enum.find(@prices, fn {key, _} -> String.contains?(m, key) end) do
      {_key, rate} -> rate
      nil -> @default_rate
    end
  end
end
