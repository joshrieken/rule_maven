defmodule RuleMaven.ExpansionDeltaTest do
  use RuleMaven.DataCase

  test "delta prompts are registered with their vars" do
    assert RuleMaven.Prompts.template("expansion_delta_system") =~ "expansion"

    rendered =
      RuleMaven.Prompts.render("expansion_delta", %{game_name: "Wingfans", rulebook: "TEXT"})

    assert rendered =~ "Wingfans"
    assert rendered =~ "TEXT"
    refute rendered =~ "{{"
  end
end
