defmodule RuleMaven.LLMContextGroupingTest do
  use ExUnit.Case, async: true
  alias RuleMaven.LLM

  @chunks [
    %{
      content: "[Page 5] majority wins",
      document_id: 1,
      label: "Core rules",
      kind: "rulebook",
      game_id: 10,
      game_name: "Ethnos"
    },
    %{
      content: "[Page 2] fairies score double",
      document_id: 2,
      label: "X errata",
      kind: "errata",
      game_id: 20,
      game_name: "Ethnos: X"
    }
  ]

  test "groups chunks under base/expansion source headers" do
    block = LLM.build_context_block(@chunks, 10)

    assert block =~ ~s(=== BASE GAME "Ethnos" — RULEBOOK "Core rules" ===)
    assert block =~ ~s(=== EXPANSION "Ethnos: X" — ERRATA "X errata" ===)
    # Chunk text sits under its own header.
    assert block =~ "[Page 5] majority wins"
  end

  test "single-source games get one header, no expansion label" do
    block = LLM.build_context_block([hd(@chunks)], 10)
    assert block =~ "BASE GAME"
    refute block =~ "EXPANSION"
  end
end
