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
  #
  # Anthropic models MUST stay in this table. The escalate model
  # (`llm_escalate_model_<provider>`) is a Claude model, and there was no Claude
  # entry here at all — so every refusal escalation fell through to
  # @default_rate {0.50, 1.50} and was logged at ~1/6 of what it actually cost.
  # On 2026-07-13 a single Sonnet escalation billed $0.326 (31% of the day's
  # entire spend) and would have been recorded as ~$0.05. The cost dashboard and
  # the budget cap both read these numbers, so the most expensive model in the
  # pipeline was the one they were blindest to. Add the model here whenever
  # `llm_escalate_model_*` changes.
  @prices [
    {"claude-opus-4", {15.00, 75.00}},
    {"claude-sonnet-5", {3.00, 15.00}},
    {"claude-sonnet-4", {3.00, 15.00}},
    {"claude-haiku-4", {1.00, 5.00}},
    {"claude-3-5-haiku", {0.80, 4.00}},
    {"deepseek-v4-flash", {0.089, 0.18}},
    {"gpt-5-mini", {0.25, 2.00}},
    {"gemini-3.1-pro", {2.00, 12.00}},
    {"gemini-2.5-flash-lite", {0.10, 0.40}},
    {"gemini-2.5-flash", {0.30, 2.50}},
    {"gemini-2.5-pro", {1.25, 10.00}},
    {"gemini-2.0-flash-lite", {0.075, 0.30}},
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

  # Fraction of the full input rate that cached input tokens are billed at.
  # Gemini implicit caching bills cached input at ~25% of the input rate; this
  # is an estimate for the savings dashboard, refine per provider as needed.
  @cached_rate_fraction 0.25

  @doc """
  USD saved by `cached_tokens` input tokens being billed at the cached rate
  instead of the full input rate, for `model`.
  """
  def cached_savings(_model, cached_tokens) when cached_tokens in [nil, 0], do: 0.0

  def cached_savings(model, cached_tokens) do
    {in_rate, _out} = rate(model)
    full = cached_tokens / 1_000_000 * in_rate
    full * (1.0 - @cached_rate_fraction)
  end

  @doc "Returns the {input, output} per-1M-token rate for a model (with fallback)."
  def rate(nil), do: @default_rate

  def rate(model) do
    m = String.downcase(model)

    # Longest match wins, regardless of table order — plain first-hit substring
    # matching priced "-lite" variants at their parent model's rate.
    @prices
    |> Enum.filter(fn {key, _} -> String.contains?(m, key) end)
    |> Enum.max_by(fn {key, _} -> String.length(key) end, fn -> {nil, @default_rate} end)
    |> elem(1)
  end
end
