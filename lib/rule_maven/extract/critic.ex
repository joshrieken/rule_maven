defmodule RuleMaven.Extract.Critic do
  @moduledoc """
  Adversarial verification loop for an escalated page — the runtime adversary.

  Given a page image and a candidate transcription, a critic model hunts for
  concrete defects (missing text, hallucinations, wrong numbers, dropped table
  rows, mis-ordered columns). If it finds any, the page is re-transcribed with
  those defects as targeted guidance, then re-critiqued. The loop runs until the
  critic is satisfied or `max_rounds` is hit — bounded so cost stays finite, and
  run only on escalated (disagreement) pages so the spend lands where accuracy is
  actually at risk.

  The model calls are injectable (`:critique_fn`, `:transcribe_fn`) so the loop
  is unit-testable without a network. Defaults wire to `RuleMaven.LLM`.

  A critic *failure* never blocks: we treat it as "no defects found" and keep the
  candidate, because a flaky critic must not throw away a usable transcription.
  """

  @default_max_rounds 2

  @doc """
  Verifies/repairs `candidate` against the page `image`. Returns
  `%{text, residual_defects, rounds, verified?}`:

    * `verified?` true  — critic found no defects (accuracy ceiling reached).
    * `verified?` false — defects remained after `max_rounds` (flag for review).

  Options: `:max_rounds` (default 2), `:critique_fn` (image, text) -> {:ok,
  [defect]} | {:error, _}, `:transcribe_fn` (image, guidance) -> {:ok, text} |
  {:error, _}.
  """
  def verify(image, candidate, opts \\ []) do
    max_rounds = opts[:max_rounds] || @default_max_rounds
    critique_fn = opts[:critique_fn] || (&default_critique/2)
    transcribe_fn = opts[:transcribe_fn] || (&default_transcribe/2)

    loop(image, candidate, 0, max_rounds, critique_fn, transcribe_fn)
  end

  defp loop(image, candidate, round, max_rounds, critique_fn, transcribe_fn) do
    case critique_fn.(image, candidate) do
      {:ok, []} ->
        %{text: candidate, residual_defects: [], rounds: round, verified?: true}

      {:error, _reason} ->
        # Critic flaked — don't block; accept the candidate, mark unverified.
        %{text: candidate, residual_defects: [], rounds: round, verified?: false}

      {:ok, defects} when round >= max_rounds ->
        # Out of repair budget; surface the residual defects for review.
        %{text: candidate, residual_defects: defects, rounds: round, verified?: false}

      {:ok, defects} ->
        # Cap the guidance fed back into the transcribe prompt: bounds prompt
        # growth and limits how much critic-authored text re-enters the model.
        guidance = defects |> Enum.take(12) |> Enum.join("\n")

        case transcribe_fn.(image, guidance) do
          {:ok, repaired} when is_binary(repaired) ->
            if String.trim(repaired) == "" do
              # Repair came back empty — keep the candidate, report the defects.
              %{text: candidate, residual_defects: defects, rounds: round + 1, verified?: false}
            else
              loop(image, repaired, round + 1, max_rounds, critique_fn, transcribe_fn)
            end

          _ ->
            # Re-transcribe failed; keep the candidate with its known defects.
            %{text: candidate, residual_defects: defects, rounds: round + 1, verified?: false}
        end
    end
  end

  defp default_critique(image, text), do: RuleMaven.LLM.critique_page(image, text)

  defp default_transcribe(image, guidance) do
    RuleMaven.LLM.transcribe_page_image(image,
      model: RuleMaven.LLM.vision_model(:escalate),
      max_tokens: 8192,
      guidance: guidance
    )
  end
end
