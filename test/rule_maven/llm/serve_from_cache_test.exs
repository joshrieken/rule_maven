defmodule RuleMaven.LLM.ServeFromCacheTest do
  # A cached answer stored before the 2026-07-14 lead-strip fix can carry an
  # inverted Yes/No lead. Served against a negatively-phrased question that lead
  # reads as the OPPOSITE verdict, so the serve path strips it (idempotent: a
  # no-op on already-stripped answers or non-negative questions).
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  defp row(answer) do
    %{
      id: 1,
      canonical_answer: nil,
      answer: answer,
      cited_passage: nil,
      cited_page: nil,
      cited_source: nil,
      citations: [],
      citation_valid: true,
      verdict: "allowed"
    }
  end

  test "strips an inverted lead from a cached answer on a negative question" do
    q = "Is it forbidden to trade before rolling?"
    {:ok, res} = LLM.__serve_from_cache__({row("**No**, trading is not allowed before rolling."), :trusted}, q)

    assert res.answer == "Trading is not allowed before rolling."
  end

  test "leaves the answer untouched on a non-negative question" do
    q = "Can a player trade before rolling?"
    {:ok, res} = LLM.__serve_from_cache__({row("**No**, you cannot."), :trusted}, q)

    assert res.answer == "**No**, you cannot."
  end
end
