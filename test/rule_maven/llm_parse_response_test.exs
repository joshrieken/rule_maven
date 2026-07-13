defmodule RuleMaven.LLMParseResponseTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  # A 200 whose body carries neither "choices" nor "error" used to fall to the
  # catch-all and come back as {:error, "Unexpected API response format"} — a
  # TERMINAL error. The ask died on "⚠️ Something went wrong. Please retry.",
  # even though the call had succeeded and been billed. Seen live from
  # OpenRouter as a bare `%{}`.
  #
  # An empty body is a flake, not a malformed contract: the right move is the
  # blank-answer retry that already exists, so these decode to an empty answer
  # and let that machinery re-ask once.
  describe "empty and content-less bodies are retryable, not terminal" do
    test "a bare empty object decodes to a blank answer" do
      assert {:ok, result} = LLM.__parse_response__(%{})
      assert result.answer == ""
      assert result.citations == []
    end

    test "a choices-less body decodes to a blank answer" do
      assert {:ok, result} = LLM.__parse_response__(%{"id" => "gen-123", "model" => "x"})
      assert result.answer == ""
    end

    test "a choice whose message has no content key decodes to a blank answer" do
      body = %{"choices" => [%{"message" => %{"role" => "assistant"}}]}
      assert {:ok, result} = LLM.__parse_response__(body)
      assert result.answer == ""
    end

    test "an empty choices list decodes to a blank answer" do
      assert {:ok, result} = LLM.__parse_response__(%{"choices" => []})
      assert result.answer == ""
    end
  end

  describe "real responses and real errors are unaffected" do
    test "a normal content response still decodes" do
      body = %{
        "choices" => [
          %{
            "message" => %{
              "content" =>
                ~s({"verdict": "info", "answer": "You move 4 spaces.", "citations": []})
            },
            "finish_reason" => "stop"
          }
        ]
      }

      assert {:ok, result} = LLM.__parse_response__(body)
      assert result.answer == "You move 4 spaces."
      assert result.finish_reason == "stop"
    end

    test "a provider error body is still an error" do
      body = %{"error" => %{"message" => "rate limited"}}
      assert {:error, "rate limited"} = LLM.__parse_response__(body)
    end

    test "an error body wins over an empty-looking shape" do
      # Must not be swallowed as a blank answer and silently retried — a real
      # upstream error should surface as one.
      body = %{"choices" => [], "error" => %{"message" => "context length exceeded"}}
      assert {:error, "context length exceeded"} = LLM.__parse_response__(body)
    end
  end
end
