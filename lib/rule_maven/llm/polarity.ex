defmodule RuleMaven.LLM.Polarity do
  @moduledoc """
  Whether a question is asked in the negative ("Can the robber NOT be placed on
  the desert?") or the positive ("Can the robber be placed on the desert?").

  This exists because the pool cannot see the difference and the LLM will not.

  A pool hit is keyed on embedding distance, and negation barely moves an
  embedding while completely INVERTING the meaning. Measured: "Can the robber NOT
  be placed on the desert hex?" landed a DIRECT pool hit on "Can the robber be
  placed on the desert hex?" and served "**Yes** — the robber can be placed on the
  desert hex." Asked "is it forbidden?", answered "Yes". Asked "is a player
  prohibited?", answered "No." Both exactly inverted, both served for FREE with no
  critic, because a pool hit skips the grounding check by design.

  The LLM tiebreaker is not a defence: it approved the polarity-flipped candidates
  itself (`pool_tiebreaker decision=true`). That is the same blindness recorded for
  the grounding critic, which rated a **Yes** citing "you may not…" as grounded 3
  times out of 3. Polarity is decided in CODE for the same reason.

  Deliberately lexical and deliberately blunt. A false "these differ" costs one
  full-price ask and returns a correct answer. A false "these agree" serves a
  confidently inverted rule to someone mid-game. The asymmetry sets the direction:
  when in doubt, differ.
  """

  # Explicit negation, plus the "is X banned?" family — which carries negative
  # polarity without containing a negative word, and which the normalizer rewrites
  # straight into a positive ("Is it forbidden to put the robber on the desert?"
  # -> "Can the robber be placed on the desert?"). That rewrite is why this must
  # run on the RAW question and not on the normalized text: by then the evidence
  # is gone.
  @negations ~w(
    not no never none cannot cant dont doesnt didnt isnt arent wasnt werent
    wont shouldnt couldnt wouldnt havent hasnt hadnt nor without
    forbidden prohibited banned illegal disallowed disallow barred
    prevented unable forbid forbids prohibit prohibits
  )

  @doc """
  True when both questions carry the same polarity, i.e. a pooled answer for one
  may be served for the other.

  Nil/blank on either side is treated as positive — an absent question cannot be
  shown to disagree, and this guard's job is to catch a flip, not to invent one.
  """
  def compatible?(a, b), do: negative?(a) == negative?(b)

  # A leading verdict word, bolded or not: "**Yes** — ", "**No**, ", "No, ".
  @lead ~r/\A\s*\**(yes|no)\**\s*[,.:;—–-]*\s*/i

  @doc """
  Drops the leading **Yes**/**No** from an answer to a NEGATIVELY-phrased question.

  The lead word is the only unreliable part of these answers. Measured across
  repeated runs of the same question, the BODY was correct every time and the lead
  flipped between runs: "**Yes**, a player is prohibited from trading before
  rolling" and "**No**, a player cannot trade before rolling" — the second's lead
  contradicts its own next clause. Asking the prompt for a more careful Yes/No
  fixed 2 of 3 runs, which is not a fix.

  So the lead is removed rather than corrected. "A player cannot trade before
  rolling for resource production." is right no matter which way the model was
  leaning, needs no extra call, and cannot invert. The `verdict` field
  (legal/illegal) still drives the verdict stamp, and it is judged on the action
  rather than on the question's phrasing.

  Positive questions keep their lead: that is where **Yes**/**No** is unambiguous
  and load-bearing, and the existing citation-contradiction check already guards it.
  """
  def strip_inverted_lead(answer, question) when is_binary(answer) do
    if negative?(question) and Regex.match?(@lead, answer) do
      answer
      |> String.replace(@lead, "")
      |> upcase_first()
    else
      answer
    end
  end

  def strip_inverted_lead(answer, _question), do: answer

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(text), do: text

  @doc """
  True when the question is asked in the negative.

  Contractions are handled by stripping apostrophes ("can't" -> "cant") rather
  than by listing both spellings. Word boundaries matter: "no" must not fire on
  "north", and "cannot" must not be missed for lack of a space.
  """
  def negative?(text) do
    text
    |> to_string()
    |> String.downcase()
    # Drop apostrophes so "can't"/"cant"/"can’t" all collapse to one token, then
    # split on anything that is not a letter. Doing this with a single regex over
    # the raw text would let "cannot" hide inside a longer word.
    |> String.replace(~r/['’]/u, "")
    |> String.split(~r/[^a-z]+/u, trim: true)
    |> Enum.any?(&(&1 in @negations))
  end
end
