defmodule RuleMaven.LLMStreamPartialTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  # __partial_answer__/1 extracts the (possibly still-open) "answer" string
  # out of the streaming ask JSON, so the LiveView can show text while the
  # rest of the object (citations, followups…) is still generating.

  test "nil until the answer field opens" do
    assert LLM.__partial_answer__("") == nil
    assert LLM.__partial_answer__("{\"ans") == nil
    assert LLM.__partial_answer__("{\"answer\":") == nil
  end

  test "extracts a partial answer mid-string" do
    assert LLM.__partial_answer__("{\"answer\": \"Roll the d20 to det") ==
             "Roll the d20 to det"
  end

  test "extracts a completed answer while later fields stream" do
    content = "{\"answer\": \"**Yes** — roll the d20.\", \"verdict\": \"legal\", \"cit"
    assert LLM.__partial_answer__(content) == "**Yes** — roll the d20."
  end

  test "unescapes JSON escapes" do
    assert LLM.__partial_answer__("{\"answer\": \"line one\\nline \\\"two\\\"") ==
             "line one\nline \"two\""
  end

  test "drops a trailing incomplete escape instead of failing" do
    assert LLM.__partial_answer__("{\"answer\": \"50\\u00b") == "50"
    assert LLM.__partial_answer__("{\"answer\": \"half \\") == "half "
  end

  test "handles unicode escapes" do
    assert LLM.__partial_answer__("{\"answer\": \"5 \\u2192 6") == "5 → 6"
  end

  # __partial_styled_answer__/1 — persona-direct path streams "styled_answer"
  # (placed right after "answer") so a persona viewer can watch it type out.

  test "styled_answer extracts independently of answer" do
    content = "{\"answer\": \"Roll the d20.\", \"styled_answer\": \"Arr, roll ye d2"

    assert LLM.__partial_answer__(content) == "Roll the d20."
    assert LLM.__partial_styled_answer__(content) == "Arr, roll ye d2"
  end

  test "styled_answer is nil until its field opens" do
    assert LLM.__partial_styled_answer__("{\"answer\": \"Roll the d20.\", \"sty") == nil
  end

  test "the styled_answer key never bleeds into the plain extraction" do
    # No plain "answer" field at all — the styled key alone must not match it.
    content = "{\"styled_answer\": \"Arr, roll ye d20"
    assert LLM.__partial_answer__(content) == nil
    assert LLM.__partial_styled_answer__(content) == "Arr, roll ye d20"
  end

  # __answer_closed__/1 & __styled_answer_closed__/1 — the field's closing
  # quote has streamed, so the visible text is final and the LiveView can swap
  # the stream cursor for the citations-pending indicator.

  test "answer not closed while the string is still open" do
    refute LLM.__answer_closed__("")
    refute LLM.__answer_closed__("{\"answer\": \"Roll the d20 to det")
    refute LLM.__answer_closed__("{\"answer\": \"escaped quote \\\"still open")
  end

  test "answer closed once the closing quote streams" do
    assert LLM.__answer_closed__("{\"answer\": \"Roll the d20.\"")
    assert LLM.__answer_closed__("{\"answer\": \"Roll the d20.\", \"cit")
    assert LLM.__answer_closed__("{\"answer\": \"quote \\\" inside\", \"verdict")
  end

  test "styled_answer closure tracked independently" do
    content = "{\"answer\": \"Roll the d20.\", \"styled_answer\": \"Arr, roll ye d2"
    assert LLM.__answer_closed__(content)
    refute LLM.__styled_answer_closed__(content)

    assert LLM.__styled_answer_closed__(content <> "0!\"")
  end

  test "a closed styled_answer alone does not close the plain answer" do
    content = "{\"styled_answer\": \"Arr!\""
    refute LLM.__answer_closed__(content)
    assert LLM.__styled_answer_closed__(content)
  end
end
