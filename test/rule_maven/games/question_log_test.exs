defmodule RuleMaven.Games.QuestionLogTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games.QuestionLog

  describe "browsable" do
    test "defaults to true and is castable" do
      changeset = QuestionLog.changeset(%QuestionLog{}, %{browsable: false})
      assert Ecto.Changeset.get_field(changeset, :browsable) == false
      assert %QuestionLog{}.browsable == true
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
