defmodule RuleMaven.Games.QuestionLogTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games.QuestionLog

  describe "browsable" do
    test "defaults to false and is castable" do
      changeset = QuestionLog.changeset(%QuestionLog{}, %{browsable: false})
      assert Ecto.Changeset.get_field(changeset, :browsable) == false
      assert %QuestionLog{}.browsable == false
    end
  end

  describe "cited_source length" do
    # cited_source comes straight from the LLM's citation JSON. A model that
    # dumps a quote/sentence into the "source" field once crashed the AskWorker
    # on insert (string_data_right_truncation against varchar(255)), leaving the
    # ask hung with no answer. The column is now unbounded text, so an oversized
    # source stores intact instead of blowing up the write.
    test "an over-length cited_source stores intact through the DB" do
      game = RuleMaven.GamesFixtures.game_fixture()
      long_source = String.duplicate("x", 400)

      {:ok, row} =
        %QuestionLog{}
        |> QuestionLog.changeset(%{
          question: "Q?",
          answer: "A.",
          game_id: game.id,
          cited_source: long_source
        })
        |> RuleMaven.Repo.insert()

      assert byte_size(row.cited_source) == 400
    end
  end

  describe "crew_origin?/1" do
    test "a solo (non-group) row awaiting the publish screen is not crew-origin" do
      pending_solo = %RuleMaven.Games.QuestionLog{
        group_id: nil,
        retracted_at: nil,
        browsable: false
      }

      refute RuleMaven.Games.QuestionLog.crew_origin?(pending_solo)
    end

    test "a group row is still crew-origin while unbrowsable" do
      group_row = %RuleMaven.Games.QuestionLog{group_id: 1, retracted_at: nil, browsable: false}
      assert RuleMaven.Games.QuestionLog.crew_origin?(group_row)
    end

    test "a deleted group's orphaned row is still crew-origin via retracted_at" do
      orphaned = %RuleMaven.Games.QuestionLog{
        group_id: nil,
        retracted_at: DateTime.utc_now(),
        browsable: false
      }

      assert RuleMaven.Games.QuestionLog.crew_origin?(orphaned)
    end
  end

  describe "listed_answer/1" do
    # A crew answer restates the asker's private question and can name real
    # people at the table — the same wording `listed_question/1` withholds. An
    # admin panel that scrubs the question but paints the answer beside it raw
    # leaks it back. `browsable` gates the answer exactly as it gates the question.

    test "shows the answer for a non-crew (browsable) row" do
      q = %QuestionLog{browsable: true, group_id: nil, answer: "Yes, per rule 7."}
      assert QuestionLog.listed_answer(q) == "Yes, per rule 7."
    end

    test "shows a screened (browsable) crew answer" do
      q = %QuestionLog{browsable: true, group_id: 5, answer: "Yes, per rule 7."}
      assert QuestionLog.listed_answer(q) == "Yes, per rule 7."
    end

    test "withholds an un-screened crew answer that echoes a real name" do
      q = %QuestionLog{browsable: false, group_id: 5, answer: "No, Sarah can't palm a card."}
      assert QuestionLog.listed_answer(q) == "(answer withheld)"
      refute QuestionLog.listed_answer(q) =~ "Sarah"
    end

    test "withholds a retracted crew answer whose crew was deleted (nilify)" do
      # group_id nilified, but retracted_at + browsable=false survive the FK drop.
      q = %QuestionLog{
        browsable: false,
        group_id: nil,
        retracted_at: ~U[2026-07-11 00:00:00Z],
        answer: "No, Sarah can't palm a card."
      }

      assert QuestionLog.listed_answer(q) == "(answer withheld)"
    end

    test "shows a curator-written canonical_answer even for an un-screened crew row" do
      q = %QuestionLog{
        browsable: false,
        group_id: 5,
        canonical_answer: "No — palming is not allowed.",
        answer: "No, Sarah can't palm a card."
      }

      assert QuestionLog.listed_answer(q) == "No — palming is not allowed."
    end
  end
end
