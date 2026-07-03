defmodule RuleMaven.LLMCleanupGuardTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  @raw String.duplicate("every word of this rule matters a lot ", 10)

  defp mock(answer) do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:ok, %{answer: answer}} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  test "hard guard (default) reverts a too-short output to raw" do
    mock("tiny")
    assert {:ok, @raw, :kept_raw} = LLM.cleanup_page(@raw, :light)
  end

  test "soft guard keeps a too-short output and reports :guard_fired" do
    mock("tiny")
    assert {:ok, "tiny", :guard_fired} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end

  test "soft guard still reverts an empty output to raw" do
    mock("   ")
    assert {:ok, @raw, :kept_raw} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end

  test "output above the floor is :cleaned either way" do
    mock(String.upcase(@raw))
    assert {:ok, _, :cleaned} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end
end
