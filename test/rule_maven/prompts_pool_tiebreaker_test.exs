defmodule RuleMaven.PromptsPoolTiebreakerTest do
  use RuleMaven.DataCase

  alias RuleMaven.Prompts

  test "pool_tiebreaker_system default instructs a strict yes/no equivalence check" do
    text = Prompts.template("pool_tiebreaker_system")
    assert text =~ "yes"
    assert text =~ "no"
  end

  test "pool_tiebreaker renders both question bindings" do
    rendered =
      Prompts.render("pool_tiebreaker", %{
        question_a: "What is the d20 used for?",
        question_b: "What does the d20 do?"
      })

    assert rendered =~ "What is the d20 used for?"
    assert rendered =~ "What does the d20 do?"
  end
end
