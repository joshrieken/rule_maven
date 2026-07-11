defmodule RuleMaven.GroupGateHolesTest do
  @moduledoc """
  Regression cover for the holes a critique pass found in the group publish
  gates. Every test here failed against the code as shipped.

  The through-line: `pooled` and `browsable` are separate on purpose (a crew's
  ANSWER may feed the commons; its question TEXT may not, until the publish
  check clears it), and each of these was a place where the text got out
  anyway — via the normalize hint block, via the tiebreaker prompt, via an
  admin promotion, or via a row that was simply born browsable.
  """
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Games, GamesFixtures, Groups, GroupsFixtures, Repo}
  alias RuleMaven.Games.QuestionLog

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

  setup do
    game = GamesFixtures.game_fixture(bgg_id: System.unique_integer([:positive]))
    member = create_user("member")
    grp = GroupsFixtures.group_fixture(member)

    %{game: game, member: member, grp: grp}
  end

  describe "list_canonical_questions/2 — the normalize hint block" do
    # The worst of the lot: this list is rendered into EVERY asker's normalize
    # prompt, and the prompt tells the model to reuse a matching entry verbatim.
    # A pooled-but-unscreened crew question in here is handed to a stranger,
    # comes back as their cleaned_question, and their row (non-group, hence
    # browsable) publishes it.
    test "an unbrowsable group row's cleaned text is not offered as a canonical hint", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp)

      refute "Can a smuggler cheat?" in Games.list_canonical_questions(ctx.game.id)
    end

    test "the same row IS offered once the publish check has cleared it", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert "Can a smuggler cheat?" in Games.list_canonical_questions(ctx.game.id)
    end

    test "an ordinary community question is still offered", ctx do
      {:ok, _q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          question: "How far do smugglers move?",
          cleaned_question: "How far does a smuggler move?",
          answer: "Two spaces.",
          visibility: "community",
          pooled: true
        })

      assert "How far does a smuggler move?" in Games.list_canonical_questions(ctx.game.id)
    end
  end

  describe "QuestionLog.changeset/2 — a group row is born unbrowsable" do
    test "an insert that forgets `browsable` still fails closed", ctx do
      {:ok, q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          group_id: ctx.grp.id,
          question: "raw wording",
          answer: "Thinking...",
          visibility: "private"
        })

      refute q.browsable
    end

    test "an explicit `browsable: true` is still honoured", ctx do
      # Guards against the trap that `browsable`'s schema default is `true`, so
      # passing true produces no Ecto *change* — a get_change/2-based check reads
      # that as "caller said nothing" and slams the row shut.
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert q.browsable
    end

    test "a non-group row is browsable by default", ctx do
      {:ok, q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          question: "ordinary question",
          answer: "Thinking...",
          visibility: "private"
        })

      assert q.browsable
    end
  end

  describe "admin promotion respects the gate" do
    # do_verify/1 enqueues a SettleVotesWorker job via Oban.insert/1, which needs
    # a named, configured instance (Oban is `testing: :manual` and unsupervised
    # in test). Same queueless/pluginless instance trust_test.exs starts — kept
    # inside this describe so it can't fight the sandbox in the LLM.ask tests.
    setup do
      start_supervised!(
        {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
      )

      :ok
    end

    test "verifying an uncleared group row is refused", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_publishable} = Games.toggle_verified(q)
      assert Repo.get(QuestionLog, q.id).visibility == "private"
    end

    test "verifying a cleared group row works", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert {:ok, _} = Games.toggle_verified(q)
      assert Repo.get(QuestionLog, q.id).visibility == "community"
    end

    test "promoting an uncleared group row to community is refused", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_publishable} = Games.update_question_visibility(q, "community")
      assert Repo.get(QuestionLog, q.id).visibility == "private"
    end

    test "set_question_visibility/2 refuses an uncleared group row too", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_publishable} = Games.set_question_visibility(q.id, "community")
      assert Repo.get(QuestionLog, q.id).visibility == "private"
    end

    test "demoting an uncleared group row to private is still allowed", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      Games.set_question_visibility(q.id, "private")
      assert Repo.get(QuestionLog, q.id).visibility == "private"
    end
  end

  describe "toggle_answer_favorite/2" do
    test "an unbrowsable pooled group row is not favoritable by a stranger", ctx do
      stranger = create_user("stranger")
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_favoritable} = Games.toggle_answer_favorite(stranger.id, q.id)
    end

    test "a cleared group row is favoritable", ctx do
      stranger = create_user("stranger")
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert {:ok, true} = Games.toggle_answer_favorite(stranger.id, q.id)
    end
  end

  describe "Groups.set_contribute/3 — turning it off is retroactive" do
    test "already-pooled crew rows stop serving the cache and stop being listed", ctx do
      cleared = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})
      pending = group_question!(ctx.game, ctx.member, ctx.grp)

      {:ok, _} = Groups.set_contribute(ctx.grp, ctx.member, false)

      for id <- [cleared.id, pending.id] do
        row = Repo.get(QuestionLog, id)
        refute row.pooled
        refute row.browsable
      end
    end

    test "a row the community already voted in is left alone", ctx do
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          browsable: true,
          visibility: "community"
        })

      {:ok, _} = Groups.set_contribute(ctx.grp, ctx.member, false)

      row = Repo.get(QuestionLog, q.id)
      assert row.pooled
      assert row.browsable
    end

    test "turning it back on does not silently re-publish the retracted rows", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      {:ok, _} = Groups.set_contribute(ctx.grp, ctx.member, false)
      {:ok, _} = Groups.set_contribute(ctx.grp, ctx.member, true)

      refute Repo.get(QuestionLog, q.id).browsable
    end

    test "a non-admin cannot flip it", ctx do
      outsider = create_user("outsider")

      assert {:error, :forbidden} = Groups.set_contribute(ctx.grp, outsider, false)
    end
  end

  describe "SuggestionsWorker's already-asked list" do
    setup ctx do
      {:ok, _doc} =
        Games.create_document(%{
          game_id: ctx.game.id,
          label: "Rulebook",
          full_text: "Smugglers move two spaces. Cheating is not allowed."
        })

      :ok
    end

    # The guard used to read `group_id && not browsable`. questions_log.group_id
    # is `on_delete: :nilify_all`, so deleting the crew stripped the group_id off
    # its rows and the guard stopped firing — waving the still-unscreened text
    # straight into a prompt whose output is shown to every visitor of the game.
    test "a deleted crew's unscreened row still never reaches the public prompt", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      {:ok, :deleted} = Groups.delete_group(ctx.member, ctx.grp)

      row = Repo.get(QuestionLog, q.id)
      assert is_nil(row.group_id), "precondition: group_id is nilified on group delete"
      refute row.browsable

      body = suggestions_prompt!(ctx.game)

      refute body =~ "SECRETWORDING"
      refute body =~ "Can a smuggler cheat?"
    end

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
  end

  describe "pool tiebreaker (paraphrase near-miss)" do
    # Same deterministic vectors llm_test.exs uses: cosine 0.88 lands the
    # candidate in the ambiguous band, which is the ONLY band that fires the
    # tiebreaker — a real provider call made on behalf of the *asker*, who here
    # is a stranger to the crew.
    @near_miss_vec_a [1.0 | List.duplicate(0.0, 767)]
    @near_miss_vec_b [0.88, 0.474_999_890_641_401_23 | List.duplicate(0.0, 766)]

    setup ctx do
      Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, @near_miss_vec_b} end)
      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      %{game: ctx.game}
    end

    defp llm_bodies!(game, question) do
      test = self()

      Application.put_env(:rule_maven, :llm_mock, fn body ->
        send(test, {:llm_body, inspect(body)})
        {:ok, %{answer: "yes", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      RuleMaven.LLM.ask(game, question)

      collect_bodies([])
    end

    defp collect_bodies(acc) do
      receive do
        {:llm_body, body} -> collect_bodies([body | acc])
      after
        0 -> acc
      end
    end

    defp with_embedding!(q, vec) do
      Repo.update_all(
        from(ql in QuestionLog, where: ql.id == ^q.id),
        set: [question_embedding: Pgvector.new(vec)]
      )

      q
    end

    test "a skip_normalize group row never puts its raw wording in the tiebreaker prompt", ctx do
      # cleaned_question: nil is the "Ask exactly this" shape — the row is still
      # pooled (its ANSWER may feed the commons), so display_question/1's raw
      # fallback was the whole leak.
      ctx.game
      |> group_question!(ctx.member, ctx.grp, %{cleaned_question: nil})
      |> with_embedding!(@near_miss_vec_a)

      bodies = llm_bodies!(ctx.game, "can a smuggler get caught cheating?")

      refute Enum.any?(bodies, &(&1 =~ "SECRETWORDING")),
             "the crew member's raw wording reached the provider under a stranger's ask"
    end

    test "an unscreened group row does not tiebreak at all — not even on its scrubbed text", ctx do
      # `browsable`, not `group_id`, is the flag that records the screen's
      # verdict. An unbrowsable crew row is either not yet screened or actively
      # REJECTED (the scrubber left a real name in), so even its cleaned_question
      # is text that must not leave the group. It misses the tiebreak entirely.
      ctx.game
      |> group_question!(ctx.member, ctx.grp)
      |> with_embedding!(@near_miss_vec_a)

      bodies = llm_bodies!(ctx.game, "can a smuggler get caught cheating?")

      refute Enum.any?(bodies, &(&1 =~ "Can a smuggler cheat?")),
             "an unscreened crew question reached the provider under a stranger's ask"

      refute Enum.any?(bodies, &(&1 =~ "SECRETWORDING"))
    end

    test "a CLEARED group row tiebreaks on its scrubbed text", ctx do
      ctx.game
      |> group_question!(ctx.member, ctx.grp, %{browsable: true})
      |> with_embedding!(@near_miss_vec_a)

      bodies = llm_bodies!(ctx.game, "can a smuggler get caught cheating?")

      assert Enum.any?(bodies, &(&1 =~ "Can a smuggler cheat?")),
             "the tiebreaker never ran on the cleared row's scrubbed text"

      refute Enum.any?(bodies, &(&1 =~ "SECRETWORDING"))
    end
  end

  describe "listed_question/1 — the one text a stranger may see" do
    test "a group row never falls back to the raw column", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{cleaned_question: nil})

      assert QuestionLog.listed_question(q) == "(question withheld)"
      refute QuestionLog.listed_question(q) =~ "SECRETWORDING"
    end

    test "a group row with scrubbed text shows the scrubbed text", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert QuestionLog.listed_question(q) == "Can a smuggler cheat?"
    end

    test "an ordinary row is unchanged", ctx do
      {:ok, q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          question: "How do I win?",
          answer: "Score points."
        })

      assert QuestionLog.listed_question(q) == "How do I win?"
    end
  end

  describe "durable admin surfaces never store raw crew wording" do
    test "the Jobs run label for a crew ask is generic", ctx do
      # job_runs.label is rendered in the admin Jobs panel — a shared surface
      # outside the group — and persists long after the ask.
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{answer: "Thinking..."})

      start_supervised!(
        {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
      )

      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        {:ok, %{answer: "No.", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      RuleMaven.Workers.AskWorker.perform(%Oban.Job{
        id: nil,
        args: %{
          "game_id" => ctx.game.id,
          "question_log_id" => q.id,
          "question" => q.question,
          "user_id" => ctx.member.id,
          "group_id" => ctx.grp.id
        }
      })

      labels = RuleMaven.Jobs.list_runs(limit: 50) |> Enum.map(& &1.label)

      refute Enum.any?(labels, &(&1 =~ "SECRETWORDING")),
             "the crew member's raw wording was written to the shared Jobs log"
    end
  end
end
