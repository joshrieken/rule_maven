defmodule RuleMaven.LLMContextGroupingTest do
  # DataCase: the block now reads each game's symbol key from the DB.
  use RuleMaven.DataCase, async: true
  alias RuleMaven.{Games, LLM, Symbols}

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

  test "appends the games' symbol keys at the end, base first, stable across calls" do
    {:ok, base} = Games.create_game(%{name: "Sym Base #{System.unique_integer([:positive])}"})
    {:ok, exp} = Games.create_game(%{name: "Sym Exp #{System.unique_integer([:positive])}"})

    {:ok, _} = Symbols.replace(base.id, [%{token: "[purple hammer symbol]", name: "Blacksmith"}])
    {:ok, _} = Symbols.replace(exp.id, [%{token: "[green horn symbol]", name: "Hunter"}])

    chunks = [
      %{hd(@chunks) | game_id: base.id, game_name: base.name},
      %{List.last(@chunks) | game_id: exp.id, game_name: exp.name}
    ]

    block = LLM.build_context_block(chunks, base.id, stable: true)

    [_, key] = String.split(block, "=== SYMBOL KEY", parts: 2)
    assert key =~ "[purple hammer symbol] = Blacksmith"
    assert key =~ "[green horn symbol] = Hunter"
    {hammer_at, _} = :binary.match(key, "Blacksmith")
    {horn_at, _} = :binary.match(key, "Hunter")
    assert hammer_at < horn_at
    assert block == LLM.build_context_block(chunks, base.id, stable: true)
  end

  test "no key, no block" do
    refute LLM.build_context_block(@chunks, 10) =~ "SYMBOL KEY"
  end
end
