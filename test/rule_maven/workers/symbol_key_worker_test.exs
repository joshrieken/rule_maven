defmodule RuleMaven.Workers.SymbolKeyWorkerTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Games, ManualImport, Symbols}
  alias RuleMaven.Workers.SymbolKeyWorker

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
    :ok
  end

  defp game_with(text) do
    {:ok, game} = Games.create_game(%{name: "SK #{System.unique_integer([:positive])}"})

    {:ok, _} =
      ManualImport.import(game, %{"pages" => [%{"sheet" => 1, "printed" => 1, "text" => text}]})

    on_exit(fn -> Symbols.clear(game.id) end)
    game
  end

  defp mock_llm(reply) do
    Process.put(:llm_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      Process.put(:llm_calls, Process.get(:llm_calls) + 1)
      {:ok, %{answer: reply}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  test "candidate_tokens collapses numbers and drops structural notes" do
    text =
      "[purple hammer symbol] [black triangle: 3] [black triangle: 7] [Caption: x] [A] [Printed page 4] [illegible]"

    assert Symbols.candidate_tokens(text) == ["[purple hammer symbol]", "[black triangle: {n}]"]
  end

  test "a book with no symbols is marked done without any LLM call" do
    game = game_with("Plain rules with no icons at all.")
    mock_llm("[]")

    assert {:ok, 0} = SymbolKeyWorker.build(game)
    assert Symbols.done?(game.id)
    assert Process.get(:llm_calls) == 0
  end

  test "keeps only candidate tokens the book contains" do
    game = game_with("Blacksmith (purple) [purple hammer symbol]. Roll [black triangle: 4].")

    mock_llm(
      Jason.encode!([
        %{
          "token" => "[purple hammer symbol]",
          "name" => "Blacksmith",
          "meaning" => "Class.",
          "aliases" => ["hammer"],
          "page" => 1
        },
        %{"token" => "[black triangle: {n}]", "name" => "black die"},
        %{"token" => "[green horn symbol]", "name" => "Hunter"}
      ])
    )

    assert {:ok, 2} = SymbolKeyWorker.build(game)

    assert Enum.map(Symbols.list(game.id), &{&1.token, &1.name, &1.source}) == [
             {"[purple hammer symbol]", "Blacksmith", "llm"},
             {"[black triangle: {n}]", "black die", "llm"}
           ]
  end

  test "a regenerate keeps hand-cropped icons for matching tokens" do
    game = game_with("[purple hammer symbol] here.")

    {:ok, _} =
      Symbols.replace(game.id, [
        %{token: "[purple hammer symbol]", name: "Old", image_path: "uploads/symbols/x.png"}
      ])

    mock_llm(Jason.encode!([%{"token" => "[purple hammer symbol]", "name" => "Blacksmith"}]))
    assert {:ok, 1} = SymbolKeyWorker.build(game)
    assert [%{name: "Blacksmith", image_path: "uploads/symbols/x.png"}] = Symbols.list(game.id)
  end
end
