defmodule RuleMaven.LLM.DropLeadTest do
  # On a negatively-phrased question the leading **Yes**/**No** flips silently.
  # drop_lead_on_negative_question strips it from the plain answer -- and must
  # ALSO strip it from the persona `styled_answer`, or the reader hears the
  # inverted lead the plain answer no longer carries.
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  @neg "Is a player prohibited from trading before rolling?"

  test "strips the inverted lead from styled_answer too" do
    res = %{
      answer: "**No**, a player cannot trade before rolling.",
      styled_answer: "No, matey — ye cannot trade afore the dice fall."
    }

    {:ok, out} = LLM.__drop_lead__({:ok, res}, @neg)

    assert out.answer == "A player cannot trade before rolling."
    assert out.styled_answer == "Matey — ye cannot trade afore the dice fall."
  end

  test "tolerates a missing/nil styled_answer" do
    {:ok, out} =
      LLM.__drop_lead__({:ok, %{answer: "**No**, cannot.", styled_answer: nil}}, @neg)

    assert out.answer == "Cannot."
    assert out.styled_answer == nil

    {:ok, out2} = LLM.__drop_lead__({:ok, %{answer: "**No**, cannot."}}, @neg)
    assert out2.answer == "Cannot."
  end

  test "leaves both untouched on a non-negative question" do
    res = %{answer: "**No**, you cannot.", styled_answer: "No, ye cannot."}
    q = "Can a player trade before rolling?"

    {:ok, out} = LLM.__drop_lead__({:ok, res}, q)

    assert out.answer == "**No**, you cannot."
    assert out.styled_answer == "No, ye cannot."
  end
end
