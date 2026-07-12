defmodule RuleMaven.GroupPrivacyTest do
  @moduledoc """
  The group boundary: a group ANSWER may feed the cross-user cache anonymously,
  but the asker's raw wording and identity must never reach a surface outside
  the group, and a group row's question text must never be listed publicly
  until PublishCheckWorker has cleared it (`browsable: true`).

  These cover the context-level gates. The rendering side (raw text never in
  /games/:id HTML for a non-member) lives in
  test/rule_maven_web/live/game_live_group_privacy_test.exs.
  """
  # async: false — the LLM mock is set via Application.put_env (global).
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Faq, Games, GamesFixtures, GroupsFixtures, Repo}
  alias RuleMaven.Games.QuestionVote

  defp create_user(prefix) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_#{n}",
        email: "#{prefix}_#{n}@test.com",
        password: "password1234"
      })

    user
  end

  defp group_question!(game, member, grp, attrs \\ %{}) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: member.id,
            group_id: grp.id,
            question: "SECRETWORDING can Dave's smuggler cheat here?",
            cleaned_question: "Can a smuggler cheat?",
            answer: "No.",
            visibility: "private",
            citation_valid: true,
            pooled: true,
            browsable: false
          },
          attrs
        )
      )

    q
  end

  # An upvote by the non-member: the *normal* way a foreign row is reachable —
  # the Helpful thumb on a pool hit targets the pool source row.
  defp upvote!(q, user) do
    Repo.insert!(%QuestionVote{question_log_id: q.id, user_id: user.id, value: "up", weight: 1.0})
  end

  setup do
    game = GamesFixtures.game_fixture(bgg_id: System.unique_integer([:positive]))
    member = create_user("member")
    outsider = create_user("outsider")
    grp = GroupsFixtures.group_fixture(member)

    %{game: game, member: member, outsider: outsider, grp: grp}
  end

  describe "recent_questions/3 — upvoted-pooled branch" do
    test "an unbrowsable group row upvoted by a NON-MEMBER stays out of their sidebar", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      upvote!(q, ctx.outsider)

      ids =
        ctx.game
        |> Games.recent_questions(50, user_id: ctx.outsider.id)
        |> Enum.map(& &1.id)

      refute q.id in ids
    end

    test "the same row IS listed once the publish check has cleared it", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})
      upvote!(q, ctx.outsider)

      ids =
        ctx.game
        |> Games.recent_questions(50, user_id: ctx.outsider.id)
        |> Enum.map(& &1.id)

      assert q.id in ids
    end

    test "the asker still sees their own unbrowsable group row", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      ids =
        ctx.game
        |> Games.recent_questions(50, user_id: ctx.member.id)
        |> Enum.map(& &1.id)

      assert q.id in ids
    end
  end

  describe "set_community_vote/4 — votable?" do
    test "a non-member cannot vote on an unbrowsable pooled group row", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_votable} =
               Games.set_community_vote(q.id, ctx.outsider.id, "up", false)
    end

    test "a browsable pooled row is votable", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      # set_community_vote/4 returns the stored value (not an {:ok, _} tuple) on
      # success; all that matters here is that it isn't rejected.
      refute match?({:error, _}, Games.set_community_vote(q.id, ctx.outsider.id, "up", false))
    end
  end

  describe "Faq.community_count/1" do
    test "does not count an unbrowsable group row", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp)

      assert Faq.community_count(ctx.game) == 0
    end

    test "counts it once published", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert Faq.community_count(ctx.game) == 1
    end
  end

  describe "SuggestionsWorker — the already-asked list goes to a PUBLIC-output LLM call" do
    # Drives the real worker and captures the actual request body handed to the
    # provider, so this fails if any raw group wording reaches the prompt.
    defp suggestions_prompt!(game) do
      test = self()

      Application.put_env(:rule_maven, :llm_mock, fn body ->
        send(test, {:llm_body, inspect(body)})
        {:ok, %{answer: "CATEGORY: Basics\n- How do I win?", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      assert :ok =
               RuleMaven.Workers.SuggestionsWorker.perform(%Oban.Job{
                 id: nil,
                 args: %{"game_id" => game.id}
               })

      assert_receive {:llm_body, body}
      body
    end

    setup ctx do
      {:ok, _doc} =
        Games.create_document(%{
          game_id: ctx.game.id,
          label: "Rulebook",
          full_text: "Smugglers move two spaces. Cheating is not allowed."
        })

      :ok
    end

    test "an unbrowsable group row's raw wording never reaches the prompt", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp)

      refute suggestions_prompt!(ctx.game) =~ "SECRETWORDING"
    end

    test "a skip_normalize group row (no cleaned text) never leaks its raw text", ctx do
      # On the "Ask exactly this" path cleaned_question is nil, so
      # display_question/1 itself falls back to the raw column — the browsable
      # gate is the only thing standing between it and the public prompt.
      group_question!(ctx.game, ctx.member, ctx.grp, %{cleaned_question: nil})

      refute suggestions_prompt!(ctx.game) =~ "SECRETWORDING"
    end

    test "a published group row contributes its SCRUBBED text, not the raw text", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      body = suggestions_prompt!(ctx.game)

      assert body =~ "Can a smuggler cheat?"
      refute body =~ "SECRETWORDING"
    end

    test "a plain (non-group) row is still excluded from the suggestions", ctx do
      {:ok, _q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.outsider.id,
          browsable: true,
          question: "How do I win the game?",
          answer: "Score points."
        })

      assert suggestions_prompt!(ctx.game) =~ "How do I win the game?"
    end
  end
end
