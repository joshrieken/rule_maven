defmodule RuleMaven.Readiness.Estimator do
  @moduledoc """
  Rough pre-run USD cost estimates for the readiness pipeline's LLM steps.

  These are deliberately approximate budgeting hints (shown next to a pending
  step before the user commits to "Prepare game"), not billing. We project token
  counts from the game's inputs — page count and rulebook character length — and
  price them with `RuleMaven.LLM.Pricing.rate/1` for the model that step uses.
  Actual spend, once a step runs, comes from `llm_logs` (see
  `LLM.cost_by_operation_for_game/2`) and supersedes the estimate in the UI.

  Heuristics use ~4 chars per token. Steps that complete already estimate $0
  (no remaining work). Embedding spend is not separately tracked in `llm_logs`,
  so its estimate is shown but there is no actual to compare against.
  """
  alias RuleMaven.{Games, Readiness, Voices}
  alias RuleMaven.LLM
  alias RuleMaven.LLM.Pricing

  @chars_per_token 4

  # Per-page vision extraction: image input + transcription output (tokens).
  @extract_in_per_page 1100
  @extract_out_per_page 700
  # Extraction also runs an accuracy critic / escalation pass on a fraction of
  # pages (two-reader cross-check). Observed ≈20-25% on top of the raw vision
  # spend; fold it in so the estimate isn't blind to ocr_critic.
  @extract_critic_factor 1.25

  # Cleanup rewrites each page into clean markdown; the formatted output runs
  # larger than the raw input (headings, lists, restored structure). Observed
  # output ≈2× the raw text tokens.
  @cleanup_out_factor 2.0

  # System-prompt overhead per chat call (tokens).
  @system_overhead 400

  # Fixed output budgets per enrichment step (tokens), matching the callers.
  @setup_out 8000
  @cheat_out 2048
  @categories_out 400
  @suggestions_out 700
  @did_you_know_out 800
  @voice_out 700
  @theme_io {1200, 1500}

  @doc """
  Estimated USD for a single step against a game's current inputs. Returns 0.0
  for non-LLM steps and for steps already complete.
  """
  def step_cost(step, %Games.Game{} = game, docs \\ nil) do
    docs = docs || Games.list_documents(game)

    cond do
      not Readiness.llm_step?(step) -> 0.0
      Readiness.step_complete?(step, game, docs) -> 0.0
      true -> do_step_cost(step, game, docs)
    end
  end

  @doc "Total estimated USD across all *pending* LLM steps (the remaining spend)."
  def remaining_cost(%Games.Game{} = game) do
    docs = Games.list_documents(game)

    Readiness.all_steps()
    |> Enum.reduce(0.0, fn step, acc -> acc + step_cost(step, game, docs) end)
  end

  @doc """
  Estimated USD to re-run prepare on an already-Ready game. The required steps
  (extract/cleanup/embed) stay complete and don't re-run — only the enrichment
  pass regenerates — so this sums the enrichment LLM steps regardless of whether
  they're already done (unlike `remaining_cost`, which would read 0).
  """
  def rerun_cost(%Games.Game{} = game) do
    docs = Games.list_documents(game)

    Readiness.enrichment_steps()
    |> Enum.reduce(0.0, fn step, acc ->
      if Readiness.llm_step?(step), do: acc + do_step_cost(step, game, docs), else: acc
    end)
  end

  # --- per-step projections ---

  defp do_step_cost(:extract, _game, docs) do
    pages = Enum.sum(Enum.map(docs, &page_count/1))
    base = price(LLM.model(), pages * @extract_in_per_page, pages * @extract_out_per_page)
    base * @extract_critic_factor
  end

  defp do_step_cost(:cleanup, _game, docs) do
    in_toks = chars(docs) |> div(@chars_per_token)
    pages = max(Enum.sum(Enum.map(docs, &page_count/1)), 1)
    out_toks = round(in_toks * @cleanup_out_factor)
    price(LLM.model(:cleanup), in_toks + pages * @system_overhead, out_toks)
  end

  defp do_step_cost(:embed, _game, docs) do
    # Embeddings: input-only, cheap. Use a representative small-embedding rate.
    in_toks = chars(docs) |> div(@chars_per_token)
    price("text-embedding-3-small", in_toks, 0)
  end

  defp do_step_cost(:suggestions, _game, docs),
    do: chat_cost(docs, @suggestions_out)

  defp do_step_cost(:categories, _game, docs),
    do: chat_cost(docs, @categories_out)

  defp do_step_cost(:cheat_sheet, _game, docs),
    do: chat_cost(docs, @cheat_out)

  defp do_step_cost(:setup, _game, docs),
    do: chat_cost(docs, @setup_out)

  defp do_step_cost(:did_you_know, _game, docs),
    do: chat_cost(docs, @did_you_know_out)

  defp do_step_cost(:voices, _game, _docs) do
    personas = length(Voices.personas())
    # Each persona restyles short text — small fixed input, capped output.
    price(LLM.model(), personas * (@system_overhead + 300), personas * @voice_out)
  end

  defp do_step_cost(:theme, _game, _docs) do
    {in_t, out_t} = @theme_io
    price(LLM.model(), in_t, out_t)
  end

  defp do_step_cost(_step, _game, _docs), do: 0.0

  # A whole-rulebook chat call: full text in + a fixed output budget.
  defp chat_cost(docs, out_tokens) do
    in_toks = div(chars(docs), @chars_per_token) + @system_overhead
    price(LLM.model(), in_toks, out_tokens)
  end

  defp price(model, in_tokens, out_tokens) do
    {in_rate, out_rate} = Pricing.rate(model)
    in_tokens / 1_000_000 * in_rate + out_tokens / 1_000_000 * out_rate
  end

  defp chars(docs), do: Enum.sum(Enum.map(docs, &String.length(&1.full_text || "")))

  defp page_count(%Games.Document{page_count: n}) when is_integer(n) and n > 0, do: n
  defp page_count(%Games.Document{pages: pages}) when is_list(pages), do: length(pages)
  defp page_count(_), do: 0
end
