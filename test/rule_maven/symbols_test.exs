defmodule RuleMaven.SymbolsTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Games, ManualImport, Readiness, Symbols, Uploads}
  alias RuleMaven.ManualImport.Enrichments

  # 1x1 transparent PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    {:ok, game} = Games.create_game(%{name: "Sym #{System.unique_integer([:positive])}"})

    {:ok, _} =
      ManualImport.import(game, %{
        "label" => "Rulebook",
        "pages" => [
          %{
            "sheet" => 3,
            "printed" => 3,
            "text" =>
              "Blacksmith (purple) [purple hammer symbol]. Roll [black triangle: 7] then [black triangle: 2]."
          }
        ]
      })

    on_exit(fn -> Symbols.clear(game.id) end)
    %{game: game}
  end

  @hammer %{
    "token" => "[purple hammer symbol]",
    "name" => "Blacksmith",
    "meaning" => "Blacksmith class.",
    "aliases" => ["hammer"],
    "page" => 3
  }
  @d8 %{
    "token" => "[black triangle: {n}]",
    "name" => "black eight-sided die",
    "meaning" => "Grid row.",
    "page" => 3
  }

  test "token_regex treats {n} as any number" do
    assert Regex.match?(Symbols.token_regex("[black triangle: {n}]"), "x [black triangle: 12] y")
    refute Regex.match?(Symbols.token_regex("[black triangle: {n}]"), "[black triangle: x]")
    assert Regex.match?(Symbols.token_regex("[Purple Hammer symbol]"), "[purple hammer symbol]")
  end

  test "import stores the key, images and completes the step", %{game: game} do
    hammer = Map.put(@hammer, "image_base64", Base.encode64(@png))
    assert {:ok, ["symbols"]} = Enrichments.import(game, %{"symbols" => [hammer, @d8]})

    [h, d] = Symbols.list(game.id)
    assert h.name == "Blacksmith" and h.aliases == ["hammer"]
    assert File.exists?(Uploads.resolve(h.image_path))
    assert d.image_path == nil
    assert Readiness.step_complete?(:symbols, Games.get_game!(game.id), [])
  end

  test "a token that is not in the book rejects the whole key", %{game: game} do
    bad = %{"token" => "[green horn symbol]", "name" => "Hunter"}

    assert {:error, {"symbols", {:tokens_not_in_book, ["[green horn symbol]"]}}} =
             Enrichments.import(game, %{"symbols" => [@hammer, bad]})

    assert Symbols.list(game.id) == []
  end

  test "an empty key records that the book has no symbols", %{game: game} do
    assert {:ok, _} = Enrichments.import(game, %{"symbols" => []})
    assert Symbols.done?(game.id)
    Symbols.clear(game.id)
    refute Symbols.done?(game.id)
  end

  test "replacing the key deletes images no longer used", %{game: game} do
    {:ok, _} =
      Enrichments.import(game, %{
        "symbols" => [Map.put(@hammer, "image_base64", Base.encode64(@png))]
      })

    [%{image_path: old}] = Symbols.list(game.id)

    {:ok, _} = Enrichments.import(game, %{"symbols" => [@hammer]})
    refute File.exists?(Uploads.resolve(old))
  end

  test "store_image rejects non-images" do
    assert {:error, :not_an_image} = Symbols.store_image(1, "<html>", "x")
  end

  test "prompt_block lists each game's key in a stable form", %{game: game} do
    {:ok, _} = Enrichments.import(game, %{"symbols" => [@hammer, @d8]})
    block = Symbols.prompt_block([game.id])

    assert block =~ "SYMBOL KEY"

    assert block =~
             "- [purple hammer symbol] = Blacksmith — Blacksmith class. (also: hammer) [p. 3]"

    assert block =~ "- [black triangle: {n}] = black eight-sided die"
    assert block == Symbols.prompt_block([game.id])
    assert Symbols.prompt_block([-1]) == ""
  end

  test "images: per-game switch and global kill switch", %{game: game} do
    assert Symbols.images_enabled?(game.id)

    Symbols.set_images(game.id, false, nil)
    refute Symbols.images_enabled?(game.id)
    Symbols.set_images(game.id, true, nil)
    assert Symbols.images_enabled?(game.id)

    RuleMaven.Flags.disable(:symbol_images)
    on_exit(fn -> RuleMaven.Flags.enable(:symbol_images) end)
    refute Symbols.images_enabled?(game.id)
  end
end
