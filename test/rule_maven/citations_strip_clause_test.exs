defmodule RuleMaven.CitationsStripClauseTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Games.Citations

  @answer """
  Heroes can counter a Monster's attack in two main ways:
  - **Discard Items**: For each **HIT** symbol rolled, you may discard one Item to avoid being defeated (Page 8).
  - **Use special action effects**: The **Fighter** can ignore any Monster Dice hit against any Hero (Page 5).

  Perk cards cannot be played during the Monster Phase (they are only playable during any Hero Phase), so they are not a way to counter an attack at that time.
  """

  test "strips an exact-substring flagged clause and keeps the rest" do
    clause =
      "Perk cards cannot be played during the Monster Phase (they are only playable during any Hero Phase), so they are not a way to counter an attack at that time."

    assert {:ok, stripped} = Citations.strip_unsupported_clause(@answer, clause)
    refute stripped =~ "Perk cards"
    assert stripped =~ "Discard Items"
    assert stripped =~ "Fighter"
  end

  test "strips a flagged bullet line even when markdown differs from the flagged text" do
    clause =
      "Use special action effects: The Fighter can ignore any Monster Dice hit against any Hero (Page 5)."

    assert {:ok, stripped} = Citations.strip_unsupported_clause(@answer, clause)
    refute stripped =~ "Fighter"
    assert stripped =~ "Discard Items"
  end

  test "returns :error when the clause cannot be located in the answer" do
    assert :error =
             Citations.strip_unsupported_clause(@answer, "Defeating a Monster lowers Terror.")
  end

  test "returns :error when stripping would gut the answer" do
    answer = "Perk cards cannot be played during the Monster Phase."
    assert :error = Citations.strip_unsupported_clause(answer, answer)
  end

  test "returns :error on nil or blank clause" do
    assert :error = Citations.strip_unsupported_clause(@answer, nil)
    assert :error = Citations.strip_unsupported_clause(@answer, "   ")
  end
end
