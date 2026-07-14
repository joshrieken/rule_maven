defmodule RuleMaven.SettingsIntAndPromptRegistryTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Prompts, Settings}

  describe "Settings.int/2" do
    test "falls back on absent, garbage, zero, and negative values" do
      assert Settings.int("tunable_missing_#{System.unique_integer([:positive])}", 7) == 7

      Settings.put("tunable_test", "not a number")
      assert Settings.int("tunable_test", 7) == 7

      Settings.put("tunable_test", "0")
      assert Settings.int("tunable_test", 7) == 7

      Settings.put("tunable_test", "-3")
      assert Settings.int("tunable_test", 7) == 7

      Settings.put("tunable_test", " 12 ")
      assert Settings.int("tunable_test", 7) == 12
    after
      Settings.delete("tunable_test")
    end
  end

  describe "prompt registry" do
    test "rulebook_url_search is registered and renders the game name" do
      assert Prompts.spec("rulebook_url_search")
      rendered = Prompts.render("rulebook_url_search", %{game_name: "Catan"})
      assert rendered =~ ~s(Official PDF rulebook URL for "Catan")
      refute rendered =~ "{{"
    end

    test "setup_verify_system is registered and non-empty" do
      assert Prompts.spec("setup_verify_system")
      assert Prompts.template("setup_verify_system") =~ "fact-checker"
    end
  end

  describe "ask call budget setting" do
    test "start_call_budget honors ask_max_llm_calls override" do
      Settings.put("ask_max_llm_calls", "3")
      :ok = RuleMaven.LLM.start_call_budget()
      assert RuleMaven.LLM.__calls_remaining__() == 3
    after
      Settings.delete("ask_max_llm_calls")
    end

    test "start_call_budget falls back to the code default when unset" do
      :ok = RuleMaven.LLM.start_call_budget()
      assert RuleMaven.LLM.__calls_remaining__() == 14
    end
  end
end
