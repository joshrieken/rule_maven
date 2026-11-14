defmodule RuleMaven.ManualImportContentTest do
  # Hand-authored enrichments and answers enter through the same storage calls
  # the LLM workers / ask pipeline use, and are held to the same bars.
  use RuleMaven.DataCase, async: false

  import Ecto.Query

  alias RuleMaven.{Games, ManualImport, Readiness, Repo, Settings}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.ManualImport.{Answers, Enrichments}

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    {:ok, game} = Games.create_game(%{name: "Content #{System.unique_integer([:positive])}"})

    {:ok, _doc} =
      ManualImport.import(game, %{
        "label" => "Core Rulebook",
        "pages" => [
          %{
            "sheet" => 10,
            "printed" => 10,
            "text" =>
              "At Mimic's location, discard [blue circle token: 6+] to battle Mimic and defeat it!"
          }
        ]
      })

    %{game: game}
  end

  @enrichments %{
    "suggestions" => [%{"category" => "Monsters", "questions" => ["How do I defeat the Mimic?"]}],
    "categories" => [
      %{"name" => "Monsters", "description" => "Monster abilities and defeat steps"}
    ],
    "cheat_sheet" => "- **Mimic**: discard a blue 6+ token to battle it.",
    "setup" => %{
      "components" => ["12 Items"],
      "setup" => [%{"title" => "Board", "detail" => "Unfold it."}]
    },
    "did_you_know" => ["The Mimic starts the game on its Monster mat, not the board."],
    "voices" => [
      %{
        "label" => "Dungeon Scribe",
        "emoji" => "📜",
        "style" => "a dry, precise scribe",
        "description" => "Precise."
      }
    ],
    "first_player" => ["Whoever last opened a treasure chest goes first."],
    "common_mistakes" => [
      %{
        "wrong" => "Battling the Mimic on its mat.",
        "right" => "It must appear on the board first."
      }
    ],
    "quiz" => [
      %{
        "q" => "Mimic's defeat cost?",
        "choices" => ["6+ blue", "Any Item"],
        "answer" => 0,
        "why" => "p.10"
      }
    ],
    "teach" => %{"goal" => "Defeat the monsters before Terror peaks."},
    "score" => [],
    "turn" => [
      %{
        "name" => "Hero Phase",
        "note" => "",
        "actions" => [%{"label" => "Move", "rule" => "Move one space."}]
      }
    ]
  }

  test "every enrichment step reads as complete after import", %{game: game} do
    assert {:ok, steps} = Enrichments.import(game, @enrichments)
    assert length(steps) == 12

    game = Games.get_game!(game.id)

    for step <- ~w(suggestions categories cheat_sheet setup did_you_know voices first_player
                   common_mistakes quiz teach score turn)a do
      assert Readiness.step_complete?(step, game, []), "#{step} not complete"
    end

    assert Settings.get("cheat_status_#{game.id}") == "done"
  end

  test "a malformed step aborts the whole import before writing", %{game: game} do
    bad =
      Map.put(@enrichments, "quiz", [
        %{"q" => "x", "choices" => ["a"], "answer" => 3, "why" => "y"}
      ])

    assert {:error, {"quiz", :shape}} = Enrichments.import(game, bad)
    refute Settings.get("suggestions_#{game.id}")
  end

  describe "theme" do
    @anchors %{
      "sets" => [
        %{
          "light" => %{
            "accent" => "#B5651D",
            "bg" => "#FAF6EF",
            "surface" => "#FFFFFF",
            "text" => "#2A2118"
          },
          "dark" => %{
            "accent" => "#E8A04A",
            "bg" => "#1B1712",
            "surface" => "#2A231B",
            "text" => "#F2EBDD"
          },
          "names" => %{"light" => "Tavern Day", "dark" => "Forge Night"}
        }
      ]
    }

    test "builds and stores the palette like the theme worker", %{game: game} do
      assert {:ok, ["theme"]} = Enrichments.import(game, %{"theme" => @anchors})

      game = Games.get_game!(game.id)
      assert [%{"light" => %{"--accent" => _}, "dark" => _}] = game.theme_palette["sets"]

      assert game.theme_names == %{
               "sets" => [%{"light" => "Tavern Day", "dark" => "Forge Night"}]
             }

      assert Readiness.step_complete?(:theme, game, [])
    end

    test "rejects malformed anchors before writing", %{game: game} do
      assert {:error, {"theme", _}} = Enrichments.import(game, %{"theme" => %{"sets" => [%{}]}})
      assert is_nil(Games.get_game!(game.id).theme_palette)
    end

    test "is refused on an expansion", %{game: game} do
      {:ok, base} = Games.create_game(%{name: "Base #{System.unique_integer([:positive])}"})
      Games.link_expansion(game.id, base.id)

      assert {:error, {"theme", :expansions_inherit_theme}} =
               Enrichments.import(game, %{"theme" => @anchors})
    end
  end

  describe "expansion_delta" do
    @delta %{
      "components" => ["4 Hazmat markers"],
      "setup" => [%{"title" => "Boards", "detail" => "Place both floors."}],
      "rules" => ["Victims cannot be thrown from the second floor."]
    }

    test "stores the delta for an expansion, so the LLM job never fires", %{game: game} do
      {:ok, base} = Games.create_game(%{name: "Base #{System.unique_integer([:positive])}"})
      Repo.insert!(%RuleMaven.Games.ExpansionLink{base_game_id: base.id, expansion_id: game.id})

      assert {:ok, ["expansion_delta"]} = Enrichments.import(game, %{"expansion_delta" => @delta})
      assert RuleMaven.ExpansionDelta.stored(game.id) == @delta
      assert RuleMaven.ExpansionDelta.status(game.id) == "done"
    end

    test "is refused on a base game", %{game: game} do
      assert {:error, {"expansion_delta", :not_an_expansion}} =
               Enrichments.import(game, %{"expansion_delta" => @delta})
    end
  end

  describe "answers for a game played with an expansion" do
    setup %{game: game} do
      {:ok, exp} = Games.create_game(%{name: "Exp #{System.unique_integer([:positive])}"})
      Games.link_expansion(exp.id, game.id)

      {:ok, exp_doc} =
        ManualImport.import(exp, %{
          "label" => "Expansion Rulebook",
          "pages" => [
            %{
              "sheet" => 2,
              "text" => "A Ladder may only be Erected outside the building for 2 AP."
            }
          ]
        })

      # Citations resolve to a document_id only for published books.
      exp_doc = Repo.update!(Ecto.Changeset.change(exp_doc, status: "published"))
      %{exp: exp, exp_doc: exp_doc}
    end

    @ladder %{
      "question" => "Where can a Ladder be Erected?",
      "answer" => "Only outside the building, for 2 AP.",
      "verdict" => "info",
      "citations" => [%{"quote" => "only be Erected outside the building for 2 AP", "page" => 2}]
    }

    test "cites the expansion's book and carries the expansion set", %{
      game: game,
      exp: exp,
      exp_doc: exp_doc
    } do
      assert {:ok, %{imported: 1, errors: []}} =
               Answers.import(game, nil, [@ladder], expansion_ids: [exp.id])

      [row] = Repo.all(from q in QuestionLog, where: q.game_id == ^game.id)
      assert row.expansion_ids == [exp.id]
      assert row.document_id == exp_doc.id
      assert row.cited_source == "Expansion Rulebook"
    end

    test "the expansion's book is not citable without the expansion", %{game: game} do
      assert {:ok, %{imported: 0, errors: [{_, {:ungrounded, _}}]}} =
               Answers.import(game, nil, [@ladder])
    end

    test "dedupe is per expansion set", %{game: game, exp: exp} do
      mimic = %{
        "question" => "How do I defeat the Mimic?",
        "answer" => "Discard a blue 6+ token at its location.",
        "verdict" => "info",
        "citations" => [%{"quote" => "At Mimic's location, discard", "page" => 10}]
      }

      assert {:ok, %{imported: 1}} = Answers.import(game, nil, [mimic])
      assert {:ok, %{imported: 1}} = Answers.import(game, nil, [mimic], expansion_ids: [exp.id])
      assert {:ok, %{skipped: 1}} = Answers.import(game, nil, [mimic], expansion_ids: [exp.id])
    end

    test "refuses a game that isn't a linked expansion", %{game: game} do
      {:ok, other} = Games.create_game(%{name: "Other #{System.unique_integer([:positive])}"})

      assert {:error, :not_an_expansion} =
               Answers.import(game, nil, [@ladder], expansion_ids: [other.id])
    end
  end

  test "a grounded answer is published and pooled; an ungrounded one is rejected", %{game: game} do
    admin = %{id: nil}

    {:ok, result} =
      Answers.import(game, admin, [
        %{
          "question" => "How do I defeat the Mimic?",
          "answer" => "At Mimic's location, discard a blue 6+ token to battle and defeat it.",
          "verdict" => "info",
          "citations" => [%{"quote" => "At Mimic's location, discard", "page" => 10}]
        },
        %{
          "question" => "Can the Mimic fly?",
          "answer" => "Yes.",
          "verdict" => "legal",
          "citations" => [
            %{"quote" => "The Mimic may fly over any obstacle on the board", "page" => 10}
          ]
        }
      ])

    assert result.imported == 1
    assert [{"Can the Mimic fly?", {:ungrounded, _}}] = result.errors

    [row] = Repo.all(from q in QuestionLog, where: q.game_id == ^game.id)
    assert row.pooled and row.browsable and row.citation_valid
    assert row.audience == "public"

    # Re-running skips what's already answered.
    {:ok, again} =
      Answers.import(game, admin, [
        %{"question" => row.question, "answer" => "x", "verdict" => "info", "citations" => []}
      ])

    assert again.skipped == 1
  end
end
