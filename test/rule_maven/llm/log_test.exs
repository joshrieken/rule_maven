defmodule RuleMaven.LLM.LogTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.LLM.Log

  describe "error_message length" do
    # A provider error body (e.g. a 401 JSON from the embedding API) can run past
    # 255 chars. error_message was varchar(255) with no length guard, so logging
    # such an error crashed the AskWorker mid-write (string_data_right_truncation)
    # — the ask hung with no answer instead of surfacing the real error. The
    # column is now unbounded text; a long error must store intact.
    test "an over-length provider error stores intact through the DB" do
      long_error =
        "Embedding API returned status 401: " <>
          String.duplicate("a", 400)

      {:ok, row} =
        %Log{}
        |> Log.changeset(%{
          provider: "openrouter",
          model: "openai/text-embedding-3-small",
          operation: "embed",
          success: false,
          error_message: long_error
        })
        |> RuleMaven.Repo.insert()

      assert row.error_message == long_error
      assert byte_size(row.error_message) > 255
    end
  end
end
