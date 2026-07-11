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
end
