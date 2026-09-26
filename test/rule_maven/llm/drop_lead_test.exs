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

  # Regression (Zombicide: Black Plague): the model said "legal", but decode's
  # lead reconciliation read the opening "No" as ❌ NOT ALLOWED. On a negative
  # question the stamp must come from the model's own verdict.
  test "a negative question keeps the model's verdict, not the lead's" do
    q = "Is there a disadvantage to attacking zombies within your own zone?"

    raw =
      ~s({"verdict": "legal", "answer": "No, there is no inherent disadvantage to attacking in your own Zone.", "citations": []})

    decoded = LLM.decode_answer(raw) |> Map.put(:raw_response, raw)
    assert decoded.verdict == "illegal"

    {:ok, out} = LLM.__drop_lead__({:ok, decoded}, q)
    assert out.verdict == "legal"
    assert out.answer == "There is no inherent disadvantage to attacking in your own Zone."
  end

  test "a positive question still lets a contradicting lead correct the stamp" do
    q = "Can I trade during another player's turn?"

    raw =
      ~s({"verdict": "legal", "answer": "No, you may not trade during another player's turn.", "citations": []})

    decoded = LLM.decode_answer(raw) |> Map.put(:raw_response, raw)
    {:ok, out} = LLM.__drop_lead__({:ok, decoded}, q)
    assert out.verdict == "illegal"
  end
end
