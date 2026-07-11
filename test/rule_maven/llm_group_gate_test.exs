defmodule RuleMaven.LLMGroupGateTest do
  @moduledoc """
  Drives `RuleMaven.LLM.ask/5` end-to-end to prove the group-membership gate
  actually denies non-members, not just that `Groups.member_of_group_id?/2`
  returns the right boolean in isolation.

  `ask/5` is the single choke point every ask path (LiveView + Oban) funnels
  through: it re-derives membership from `opts[:user_id]` before honoring a
  caller-supplied `opts[:group_id]` (see the comment at the top of `ask/5` in
  lib/rule_maven/llm.ex). `group_id` rides in as an Oban job arg / LiveView
  assign, so it is not proof of membership on its own — a forged or stale
  value must never widen the pool lookup to a group the asker isn't in.

  This test uses `Application.put_env(:rule_maven, :llm_mock, ...)` and
  `:embed_mock`, the same mocking mechanism the rest of the LLM test suite
  uses (see test/rule_maven/llm_test.exs). Not `async: true` — the mocks are
  global process env, same as every other file that sets them.
  """
  use RuleMaven.DataCase

  alias RuleMaven.{LLM, Games, Groups, Repo}
  alias RuleMaven.GroupsFixtures

  @emb Enum.to_list(1..768)

  defp create_user(prefix) do
    Repo.insert!(%RuleMaven.Users.User{
      username: "#{prefix}_#{System.unique_integer([:positive])}",
      email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp mock_embed(vec) do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, vec} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
  end

  setup do
    {:ok, game} = Games.create_game(%{name: "GroupGateGame"})
    owner = create_user("gate_owner")
    grp = GroupsFixtures.group_fixture(owner)

    {:ok, group_q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How many actions per turn in the group?",
        answer: "GROUP-PRIVATE-ANSWER: three actions.",
        visibility: "private",
        group_id: grp.id,
        citation_valid: true
      })

    Repo.update_all(
      Ecto.Query.from(x in Games.QuestionLog, where: x.id == ^group_q.id),
      set: [question_embedding: Pgvector.new(@emb)]
    )

    # Sanity: the row really is in the group, and the outsider really isn't a
    # member — otherwise the test below wouldn't be testing what it claims to.
    refute Groups.member_of_group_id?(nil, grp.id)

    mock_embed(@emb)

    %{game: game, grp: grp, owner: owner, group_q: group_q}
  end

  test "a non-member asking the same question NEVER gets served the group's private row",
       %{game: game, grp: grp, group_q: group_q} do
    outsider = create_user("gate_outsider")
    refute Groups.member_of_group_id?(outsider.id, grp.id)

    mock_llm(fn _body ->
      {:ok,
       %{
         answer: "FRESH-LLM-ANSWER: not the group's cached answer.",
         cited_passage: "some rulebook text",
         followup: false,
         followups: []
       }}
    end)

    {:ok, result} =
      LLM.ask(game, "How many actions per turn in the group?", [], [],
        user_id: outsider.id,
        group_id: grp.id,
        skip_normalize: true
      )

    # The forged group_id must not widen the pool lookup: no pool hit at all,
    # and specifically not a hit on the group's row. The outsider gets a
    # fresh LLM answer instead.
    refute result[:pool_hit] == true
    refute result[:source_question_log_id] == group_q.id
    assert result.answer =~ "FRESH-LLM-ANSWER"
    refute result.answer =~ "GROUP-PRIVATE-ANSWER"
  end

  test "a real member asking the same question DOES get served the group's cached row",
       %{game: game, grp: grp, owner: owner, group_q: group_q} do
    assert Groups.member_of_group_id?(owner.id, grp.id)

    # If this fires, the gate failed open (the member should be served from
    # cache and never reach the LLM for this question).
    mock_llm(fn _body ->
      flunk("LLM should not be called — the member's ask should hit the group cache")
    end)

    {:ok, result} =
      LLM.ask(game, "How many actions per turn in the group?", [], [],
        user_id: owner.id,
        group_id: grp.id,
        skip_normalize: true
      )

    assert result[:pool_hit] == true
    assert result[:source_question_log_id] == group_q.id
    assert result.answer =~ "GROUP-PRIVATE-ANSWER"
  end
end
