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

  # __partial_verdict__/1 — the schema now puts "verdict" first so the
  # streaming path knows it before any answer text arrives.

  test "verdict is nil until its string closes" do
    assert LLM.__partial_verdict__("") == nil
    assert LLM.__partial_verdict__("{\"verdict\": \"in") == nil
    assert LLM.__partial_verdict__("{\"verdict\": \"info\"") == "info"
    assert LLM.__partial_verdict__("{\"verdict\": \"legal\", \"answer\": \"Ro") == "legal"
  end

  # __partial_display_answer__/1 — what the LiveView shows while streaming.
  # Must always match what decode_answer/1 produces for the same content, so
  # the text never visibly changes when :ask_complete swaps the final in.

  test "plain text passes through unchanged" do
    content = "{\"verdict\": \"info\", \"answer\": \"Roll the d20 to det"
    assert LLM.__partial_display_answer__(content) == "Roll the d20 to det"
  end

  test "info verdict strips a Yes/No lead once the tail can stand alone" do
    content =
      "{\"verdict\": \"info\", \"answer\": \"Yes. During the set-up phase, each player builds 1 road"

    assert LLM.__partial_display_answer__(content) ==
             "During the set-up phase, each player builds 1 road"
  end

  test "info verdict recapitalizes after stripping the lead" do
    content =
      "{\"verdict\": \"info\", \"answer\": \"**Yes** — the robber moves to the chosen hex and stays"

    assert LLM.__partial_display_answer__(content) ==
             "The robber moves to the chosen hex and stays"
  end

  test "info verdict holds (nil) while the tail is still too short to strip" do
    content = "{\"verdict\": \"info\", \"answer\": \"Yes. During the set"
    assert LLM.__partial_display_answer__(content) == nil
  end

  test "info verdict keeps the lead when the answer closes with a short tail" do
    content = "{\"verdict\": \"info\", \"answer\": \"Yes. Roll the d20.\""
    assert LLM.__partial_display_answer__(content) == "Yes. Roll the d20."
  end

  test "legal/illegal verdicts keep the Yes/No lead" do
    content = "{\"verdict\": \"legal\", \"answer\": \"**Yes** — a settlement can be upgraded to a city"

    assert LLM.__partial_display_answer__(content) ==
             "**Yes** — a settlement can be upgraded to a city"
  end

  test "missing verdict holds a Yes/No lead until the answer closes" do
    open = "{\"answer\": \"Yes. During the set-up phase, each player builds 1 road"
    assert LLM.__partial_display_answer__(open) == nil

    # Closed with no verdict: decode_answer would keep the lead → so do we.
    closed = open <> "\""
    assert LLM.__partial_display_answer__(closed) == "Yes. During the set-up phase, each player builds 1 road"
  end

  test "silent verdict suppresses the doomed answer text entirely" do
    content =
      "{\"verdict\": \"silent\", \"answer\": \"No, a monster cannot be defeated in one attack"

    assert LLM.__partial_display_answer__(content) == nil
  end

  test "non-English answer text is suppressed entirely while streaming" do
    # AskWorker's output guard replaces a wrong-language answer with a retry
    # warning at :ask_complete — streaming the doomed Chinese text first showed
    # the reader an answer that then vanished.
    content =
      "{\"verdict\": \"info\", \"answer\": \"你可以在游戏过程中建造第三个定居点，但前提是已完成初始设置阶段"

    assert LLM.__partial_display_answer__(content) == nil
    assert LLM.__partial_display_answer__(content <> "。\"") == nil
  end

  test "non-English styled text is suppressed too" do
    content = "{\"answer\": \"Roll the d20.\", \"styled_answer\": \"你可以在游戏过程中建造第三个定居点，但前提是"
    assert LLM.__partial_styled_answer__(content) == nil
  end

  test "trims the answer once its string closes" do
    content = "{\"verdict\": \"info\", \"answer\": \"  Roll the d20 to determine the outcome.  \""
    assert LLM.__partial_display_answer__(content) == "Roll the d20 to determine the outcome."
  end
end
