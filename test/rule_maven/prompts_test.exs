defmodule RuleMaven.PromptsTest do
  use RuleMaven.DataCase

  alias RuleMaven.Prompts

  describe "answer template" do
    test "empty voice_style: no styled_answer mention, no stray placeholder" do
      rendered = Prompts.render("answer", %{
        game_name: "Test",
        game_kind: "board game",
        context_block: "",
        rulebook: "",
        voice_style: ""
      })

      refute rendered =~ "styled_answer"
      refute rendered =~ "{{voice_style}}"
    end

    test "non-empty voice_style substitutes in and mentions styled_answer" do
      rendered = Prompts.render("answer", %{
        game_name: "Test",
        game_kind: "board game",
        context_block: "",
        rulebook: "",
        voice_style: "VOICE INSTRUCTIONS — the asker has an active persona selected. Include a \"styled_answer\" field."
      })

      assert rendered =~ "VOICE INSTRUCTIONS — the asker has an active persona selected."
      assert rendered =~ "styled_answer"
      refute rendered =~ "{{voice_style}}"
    end
  end
end
