defmodule RuleMavenWeb.GameLive.ReaskContextTest do
  use ExUnit.Case, async: true

  alias RuleMavenWeb.GameLive.Show

  test "a re-ask quotes the thread's turns before the retried row, not after it" do
    convo = [
      %{id: 1, role: :user, content: "How many cards do I draw?"},
      %{id: 1, role: :assistant, content: "Two."},
      %{id: 2, role: :user, content: "Old regen", history: true},
      %{id: 2, role: :assistant, content: "Superseded", history: true},
      %{id: 3, role: :user, content: "And at night?"},
      %{id: 3, role: :assistant, content: "Three."},
      %{id: 4, role: :user, content: "Later turn"},
      %{id: 4, role: :assistant, content: "Later answer"}
    ]

    assert Enum.map(Show.reask_prior_turns(convo, 3), & &1.content) == [
             "How many cards do I draw?",
             "Two."
           ]

    assert Show.reask_prior_turns(convo, 1) == []
  end

  test "in-flight turns are left out" do
    convo = [
      %{id: 1, role: :user, content: "Q"},
      %{id: 1, role: :assistant, content: "Thinking...", pending: true},
      %{id: 2, role: :user, content: "Retry me"}
    ]

    assert Enum.map(Show.reask_prior_turns(convo, 2), & &1.content) == ["Q"]
  end
end
