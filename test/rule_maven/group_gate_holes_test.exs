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

  # A voter the promotion quorum will actually count: confirmed email, and old
  # enough (vote_min_age_hours is 0 outside prod, so creation time is fine).
  defp confirmed(user) do
    user
    |> Ecto.Changeset.change(%{email_confirmed_at: DateTime.utc_now(:second)})
    |> Repo.update!()
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
            promoted: false,
            citation_valid: true,
            pooled: true,
            browsable: false,
            # These rows stand in for questions the normalize step actually
            # rewrote — the premise the whole publish gate rests on. A row that
            # records no scrub is withheld; that is its own test below.
            question_normalized: true
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
          promoted: true,
          pooled: true,
          browsable: true
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
          promoted: false
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

    test "a non-group row is ALSO born unbrowsable by default, same as a group row", ctx do
      # This used to assert the opposite: a solo/non-group row defaulted
      # `browsable: true` and only group rows were born closed. The unified
      # publish gate removed that asymmetry — every row, solo or group, now
      # waits on PublishCheckWorker before its question text can be listed.
      {:ok, q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          question: "ordinary question",
          answer: "Thinking...",
          promoted: false
        })

      refute q.browsable
    end
  end

  describe "admin promotion respects the gate" do
    # do_verify/1 enqueues a SettleVotesWorker job via Oban.insert/1, which needs
    # a named, configured instance (Oban is `testing: :manual` and unsupervised
    # in test). Same queueless/pluginless instance trust_test.exs starts — kept
    # inside this describe so it can't fight the sandbox in the LLM.ask tests.
    setup do
      start_supervised!(
        {Oban,
         repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
      )

      :ok
    end

    test "verifying an uncleared group row is refused", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:error, :not_publishable} = Games.toggle_verified(q)
      refute Repo.get(QuestionLog, q.id).promoted
    end

    test "verifying a cleared group row works", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert {:ok, _} = Games.toggle_verified(q)
      assert Repo.get(QuestionLog, q.id).promoted
    end

    test "demoting a row is always allowed", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      Games.demote_question(q.id)
      refute Repo.get(QuestionLog, q.id).promoted
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

    test "an unscreened group row does not tiebreak at all — not even on its scrubbed text",
         ctx do
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

    test "a crew member DOES tiebreak against their own crew's unscreened row", ctx do
      # The crew's private answer cache is the whole point of the feature. The
      # asker's membership in `active_group_id` is verified upstream in LLM.ask/5,
      # so serving them their own crew's row crosses no boundary — gating the
      # tiebreak on `browsable` alone made two crew members asking paraphrases
      # both pay for a full ask.
      ctx.game
      |> group_question!(ctx.member, ctx.grp)
      |> with_embedding!(@near_miss_vec_a)

      test = self()

      Application.put_env(:rule_maven, :llm_mock, fn body ->
        send(test, {:llm_body, inspect(body)})
        {:ok, %{answer: "yes", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      RuleMaven.LLM.ask(ctx.game, "can a smuggler get caught cheating?", [], [],
        user_id: ctx.member.id,
        group_id: ctx.grp.id
      )

      bodies = collect_bodies([])

      assert Enum.any?(bodies, &(&1 =~ "Can a smuggler cheat?")),
             "the crew's own private cache never reached the tiebreaker for its own member"
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

    test "an ordinary row shows raw text once cleared (same gate as a group row, no scrub needed)",
         ctx do
      {:ok, q} =
        Games.log_question(%{
          game_id: ctx.game.id,
          user_id: ctx.member.id,
          question: "How do I win?",
          answer: "Score points.",
          browsable: true
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
        {Oban,
         repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
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

  describe "Groups.delete_group/2" do
    test "retracts the crew's rows before nilifying their group_id", ctx do
      # group_id is on_delete: :nilify_all, so after the delete nothing on the row
      # says it came from a crew. Close the rows while we can still find them —
      # otherwise every group_id-keyed guard downstream misjudges them. The
      # closing is retroactive: both a screen-cleared row and one still pending
      # the screen are pulled, and `retracted_at` is the durable stamp — unlike
      # pooled/browsable, nothing in the ask pipeline ever rewrites it, so a
      # deleted crew's withdrawal cannot be undone by a later re-run.
      cleared = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})
      pending = group_question!(ctx.game, ctx.member, ctx.grp)

      {:ok, :deleted} = Groups.delete_group(ctx.member, ctx.grp)

      for id <- [cleared.id, pending.id] do
        row = Repo.get(QuestionLog, id)
        assert is_nil(row.group_id), "precondition: group_id is nilified"
        refute row.browsable, "a deleted crew's row stayed publicly listable"
        refute row.pooled
        assert row.retracted_at, "the withdrawal left no durable trace"
      end
    end

    test "a row the community already voted in is left alone", ctx do
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          browsable: true,
          promoted: true
        })

      {:ok, :deleted} = Groups.delete_group(ctx.member, ctx.grp)

      row = Repo.get(QuestionLog, q.id)
      assert row.pooled
      assert row.browsable
    end

    test "a non-owner cannot delete", ctx do
      stranger = create_user("stranger")

      assert {:error, :forbidden} = Groups.delete_group(stranger, ctx.grp)
    end
  end

  describe "listed_question/1 needs BOTH axes" do
    test "a cleared crew row still never falls back to the raw column", ctx do
      # browsable: true says the SCRUBBED text passed the screen — it says nothing
      # about the raw column, which is exactly what the scrub removed.
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          browsable: true,
          cleaned_question: nil
        })

      assert QuestionLog.listed_question(q) == "(question withheld)"
      refute QuestionLog.listed_question(q) =~ "SECRETWORDING"
    end
  end

  describe "the normalize FALLBACK is not a scrub" do
    # normalize_question/4 falls back to the RAW question on any failure (a 429, a
    # timeout, a rewrite accept_normalized?/2 rejects), and that fallback is what
    # lands in cleaned_question. Screening it and publishing it would hand the
    # asker's verbatim prose to the public browse under the scrubbed column's name.
    # The stored fallback text is NOT byte-identical to the raw question, which is
    # why the original equality guard was dead code: `strip_game_name/2` appends a
    # "?" when the text doesn't end in one, so a fallback on "…, Sam says no" is
    # stored as "…, Sam says no?" — never equal to the raw column. The gate asks the
    # row whether normalize ran, rather than trying to infer it from the text.
    test "a normalize FALLBACK is never published, even though its text differs from the raw",
         ctx do
      raw = "SECRETWORDING Dave says my smuggler can cheat, Sam says no"

      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          question: raw,
          # Exactly what the fallback path stores: the raw prose, plus a "?".
          cleaned_question: raw <> "?",
          question_normalized: false
        })

      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        flunk("the publish screen was called on un-normalized text")
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      assert :ok =
               RuleMaven.Workers.PublishCheckWorker.perform(%Oban.Job{
                 id: nil,
                 args: %{"question_log_id" => q.id}
               })

      refute Repo.get(QuestionLog, q.id).browsable
    end

    test "a genuinely rewritten question still publishes", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        {:ok, %{answer: "no", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      assert :ok =
               RuleMaven.Workers.PublishCheckWorker.perform(%Oban.Job{
                 id: nil,
                 args: %{"question_log_id" => q.id}
               })

      assert Repo.get(QuestionLog, q.id).browsable
    end

    test "a row withdrawn during the LLM call is not re-published", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)

      # Simulate retract_contributions committing inside the screen's LLM window
      # — a crew deletion is what triggers it now.
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        {:ok, :deleted} = Groups.delete_group(ctx.member, ctx.grp)
        {:ok, %{answer: "no", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      assert :ok =
               RuleMaven.Workers.PublishCheckWorker.perform(%Oban.Job{
                 id: nil,
                 args: %{"question_log_id" => q.id}
               })

      refute Repo.get(QuestionLog, q.id).browsable,
             "the screen re-opened a row the crew had just withdrawn"
    end
  end

  describe "crew votes on an invisible row buy nothing" do
    test "a fellow crew member's vote on an unbrowsable row carries zero weight", ctx do
      # The promotion quorum means INDEPENDENT review. An unbrowsable crew row has
      # no public surface, so the only possible voters are the crew — three of whom
      # would otherwise clear both the trust floor and the quorum between them, on a
      # row no outsider can see.
      mate = create_user("crewmate")
      {:ok, _} = Groups.join_by_code(mate, ctx.grp.invite_code)

      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert "up" = Games.set_community_vote(q.id, mate.id, "up", false)

      vote = Repo.get_by(RuleMaven.Games.QuestionVote, question_log_id: q.id, user_id: mate.id)

      assert vote, "the vote was recorded (the thumb still works)"
      assert vote.weight == 0.0, "a crew vote on an invisible row moved trust"
    end

    test "the same vote carries real weight once the row is published", ctx do
      mate = create_user("crewmate2")
      {:ok, _} = Groups.join_by_code(mate, ctx.grp.invite_code)

      q = group_question!(ctx.game, ctx.member, ctx.grp, %{browsable: true})

      assert "up" = Games.set_community_vote(q.id, mate.id, "up", false)

      vote = Repo.get_by(RuleMaven.Games.QuestionVote, question_log_id: q.id, user_id: mate.id)

      assert vote.weight > 0.0
    end

    # Round 5 zeroed the WEIGHT of a crew's votes on its own invisible row, which
    # stopped them moving trust. It did not stop them being COUNTED. The promotion
    # gate is two independent conditions — a trust floor AND a distinct-voter
    # quorum — and `eligible_voter_count/2` counted every voter regardless of
    # weight. So the crew could still supply the quorum with votes worth nothing,
    # leaving one outside high-rep upvote to carry the floor on its own.
    test "zero-weight crew votes do not count toward the promotion quorum", ctx do
      # Both voters must be ELIGIBLE on every other axis the quorum checks
      # (confirmed email, account age), or this test passes for the wrong reason:
      # eligible_voter_count would return 0 whether or not it filters on weight.
      mate1 = confirmed(create_user("quorum1"))
      mate2 = confirmed(create_user("quorum2"))
      {:ok, _} = Groups.join_by_code(mate1, ctx.grp.invite_code)
      {:ok, _} = Groups.join_by_code(mate2, ctx.grp.invite_code)

      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert "up" = Games.set_community_vote(q.id, mate1.id, "up", false)
      assert "up" = Games.set_community_vote(q.id, mate2.id, "up", false)

      # Both votes exist and both are weightless.
      assert Repo.aggregate(
               from(v in RuleMaven.Games.QuestionVote, where: v.question_log_id == ^q.id),
               :count
             ) == 2

      assert RuleMaven.Games.Trust.eligible_voter_count(q.id, ctx.member.id) == 0,
             "an invisible crew row reached the promotion quorum on votes nobody outside could see"
    end
  end

  describe "also_asked — the second copy of the raw question" do
    # The answer prompt asks the model for "the exact text of the additional
    # questions" when one message carries more than one, so `also_asked` holds the
    # asker's VERBATIM prose — outside the question/cleaned/canonical triad that
    # every gate mediates, and rendered to readers as "Related questions" chips.
    test "the publish screen sees also_asked, so a name in it withholds the row", ctx do
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          also_asked: ["and does Dave's house rule break the endgame?"]
        })

      # Asserted through the WORKER, not through `screen_text/2` in isolation.
      # Asserting on the pure helper stopped one seam short of the gate: it never
      # proved that `decide/3` feeds the helper's output into the prompt, so
      # reverting the fix (rendering the bare `cleaned` instead of the blob) left
      # the old assertion green.
      test_pid = self()

      Application.put_env(:rule_maven, :llm_mock, fn body ->
        send(test_pid, {:screened, inspect(body)})
        # The name is in `also_asked`, so a screen that actually reads it says yes.
        {:ok, %{answer: "yes", finish_reason: "stop"}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      start_supervised!(
        {Oban,
         repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
      )

      assert :ok =
               RuleMaven.Workers.PublishCheckWorker.perform(%Oban.Job{
                 id: 1,
                 args: %{"question_log_id" => q.id}
               })

      assert_received {:screened, body}

      assert body =~ "Dave&#39;s house rule" or body =~ "Dave's house rule",
             "also_asked never reached the privacy screen"

      row = Repo.get(QuestionLog, q.id)
      refute row.browsable, "a name in also_asked did not withhold the row"
    end
  end

  describe "a crew row is not reportable by a stranger" do
    # `find_question_log/2` is scoped by GAME only, and `report_answer/3` had none of
    # the reachability checks its siblings (`votable?/2`, `toggle_answer_favorite/2`)
    # apply. So any logged-in stranger could push `open_report` with a guessed id.
    #
    # And one report was enough: a crew row's trust_score is 0 by construction (crew
    # votes on an unbrowsable row are weight 0), so `pool_tier/2` reads :provisional
    # and `maybe_auto_pull/1` sets `needs_review` on the FIRST flag — no quorum. That
    # killed the crew's own cache, blocked re-pooling of the whole topic cluster for
    # every user in the game, doubled the asker's abuse-risk score, and put their raw
    # never-screened question on the moderator dashboard next to a Delete button.
    test "a non-member cannot report a crew's unbrowsable row", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      stranger = create_user("report_stranger")

      assert {:error, :not_found} = Games.report_answer(q.id, stranger)

      refute Repo.get!(QuestionLog, q.id).needs_review,
             "a stranger flagged a crew's private row and pulled it from the crew's own cache"
    end

    test "a crew member CAN still report their crew's row", ctx do
      mate = create_user("report_mate")
      {:ok, _} = Groups.join_by_code(mate, ctx.grp.invite_code)

      q = group_question!(ctx.game, ctx.member, ctx.grp)

      assert {:ok, _} = Games.report_answer(q.id, mate)
    end
  end

  describe "removing a member actually removes them" do
    # The invite URL is rendered to EVERY member, and join_by_code checks only that
    # the code exists and is active — there is no blocklist. Deleting the membership
    # row alone left the removed member holding a working key.
    test "remove_member rotates the invite code so the old link is dead", ctx do
      mate = create_user("removed")
      {:ok, _} = Groups.join_by_code(mate, ctx.grp.invite_code)

      stale_code = ctx.grp.invite_code

      assert {:ok, :removed} = Groups.remove_member(ctx.member, ctx.grp, mate.id)

      assert {:error, :invalid_code} = Groups.join_by_code(mate, stale_code),
             "a removed member walked straight back in with the link they already had"
    end
  end

  describe "round 10 — listed_question trusts a scrub that never ran" do
    # `cleaned_question` is only a scrub if normalize actually RAN. On a fallback
    # (429, timeout, rejected rewrite) AskWorker stores the asker's verbatim prose
    # in that column. `listed_question/1` used to fall back to it unconditionally,
    # which handed the raw prose — names and all — to every admin list, and to the
    # admin search box as a substring oracle.
    test "an unnormalized cleaned_question is never listed", ctx do
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          question: "does Dave's rogue sneak past when Sarah blocks?",
          cleaned_question: "does Dave's rogue sneak past when Sarah blocks?",
          question_normalized: false
        })

      listed = QuestionLog.listed_question(q)

      refute listed =~ "Dave"
      refute listed =~ "Sarah"
      assert listed == "(question withheld)"
    end

    test "the admin search box CAN match it — admin_list_questions is gated to :admin and reads raw columns on purpose",
         ctx do
      # A later fix in this same branch (984d9b9) made this deliberate: the
      # Questions list is mounted with an `:admin`-only gate, so the withholding
      # gate that protects *other users* (`listed_question/1`/`listed_answer/1`)
      # doesn't need to apply to the admin's own search box — an admin reviewing
      # an unscreened row should be able to find it by its raw wording. This used
      # to assert the opposite (search as a blind oracle risk), before that fix
      # made raw-column search an explicit, intended admin capability.
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          question: "does Dave's rogue sneak past?",
          cleaned_question: "does Dave's rogue sneak past?",
          question_normalized: false
        })

      assert [found] = Games.admin_list_questions(search: "Dave")
      assert found.id == q.id
    end

    test "a genuinely scrubbed cleaned_question still lists", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      assert QuestionLog.listed_question(q) == "Can a smuggler cheat?"
    end

    test "the admin search box CAN match a withheld crew ANSWER too, for the same reason", ctx do
      # The answer restates the private question ("No, Sarah may not…"), and
      # `listed_answer/1` withholds it on every OTHER surface for an unbrowsable
      # crew row. But `admin_list_questions/1` is the admin-only Questions list
      # (984d9b9), which intentionally reads the raw `answer` column — an admin
      # reviewing a report needs to find the row by its actual wording.
      q =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          answer: "No, ORACLETOKEN may not palm a card."
        })

      assert [found] = Games.admin_list_questions(search: "ORACLETOKEN")
      assert found.id == q.id
    end

    test "a browsable answer is still searchable (no false-withhold)", ctx do
      group_question!(ctx.game, ctx.member, ctx.grp, %{
        answer: "Yes, FINDME is allowed.",
        browsable: true
      })

      assert [_] = Games.admin_list_questions(search: "FINDME")
    end
  end

  describe "round 10 — a crew row is not readable by house-rule delta" do
    test "a stranger cannot pair their own house rule with a crew row", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      stranger = create_user("stranger")

      {:ok, hr} =
        RuleMaven.HouseRules.create(stranger, ctx.game.id, %{
          title: "Mine",
          body: "Players may reroll once per turn."
        })

      # Owning the house rule says nothing about being allowed to READ the row the
      # delta is computed against — and the delta prompt feeds that row's question
      # and answer to the LLM, then renders the summary back to the requester.
      assert {:error, :not_found} = RuleMaven.HouseRules.request_delta(stranger, hr, q)
    end

    # The guard is `Games.reachable_by?/2`. Asserted directly rather than through
    # `request_delta/3`, whose success path enqueues an Oban job (no instance runs
    # in this test file) — the interesting fact is that the crew member passes the
    # reachability check the stranger fails, not what happens after it.
    test "a fellow crew member is reachable, a stranger is not", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      mate = create_user("mate")
      {:ok, _} = Groups.join_by_code(mate, ctx.grp.invite_code)
      stranger = create_user("stranger2")

      assert Games.reachable_by?(q, mate.id)
      assert Games.reachable_by?(q, ctx.member.id)
      refute Games.reachable_by?(q, stranger.id)
    end
  end

  describe "round 10 — an orphaned crew row earns no promotion quorum" do
    # `group_id` is `on_delete: :nilify_all`, so a deleted crew's rows keep their
    # unscreened text and lose the marker that says where it came from. Two layers
    # have to hold for such a row:
    #
    #   1. It is not votable at all by an outsider — `reachable_by?/2` sees an
    #      unbrowsable row that isn't theirs. This is the live gate.
    #   2. Even if it WERE votable, `unreviewable?` now keys on `crew_origin?/1`
    #      rather than `group_id`, so any vote it did collect would be weight 0 and
    #      buy no promotion quorum. This is the backstop the nilify trap defeated.
    test "an outsider cannot vote on a nilified, unbrowsable crew row at all", ctx do
      q = group_question!(ctx.game, ctx.member, ctx.grp)
      voter = create_user("voter") |> confirmed()

      # Nilify the marker the way a group deletion does.
      q = q |> Ecto.Changeset.change(%{group_id: nil}) |> Repo.update!()

      assert {:error, :not_votable} = Games.set_community_vote(q.id, voter.id, "up")
    end
  end

  describe "round 11 — a screen-REJECTED turn is not quoted into a solo ask" do
    # `question_normalized: true` means normalize RAN, not that it WORKED.
    # PublishCheckWorker exists because it doesn't always work: an unambiguous
    # "yes" is the system proving the scrub failed — the screen read the row's text
    # and found a real person still in it. Such a row keeps question_normalized:
    # true and a cleaned_question that still says "Dave", and is withheld
    # (browsable: false).
    #
    # Quoting it into a SOLO follow-up in the same thread (flip the crew selector
    # to "Just me"; the conversation survives in the socket) put those names into
    # the new ask's prompt — and the new row is born browsable and gets pooled, so
    # the names ride into an answer served to strangers, on a row the screen never
    # even looks at.
    test "the rejected crew turn is dropped from a solo ask's context", ctx do
      # A row the screen REJECTED: normalize ran, the scrub missed a name, withheld.
      rejected =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          cleaned_question: "Can Dave's rogue steal from Sarah's satchel?",
          question_normalized: true,
          browsable: false,
          pooled: false
        })

      convo = [
        %{
          id: rejected.id,
          role: :user,
          content: rejected.question,
          cleaned_question: rejected.cleaned_question,
          question_normalized: rejected.question_normalized,
          group_id: rejected.group_id,
          browsable: rejected.browsable
        },
        %{id: rejected.id, role: :assistant, content: rejected.answer}
      ]

      # dest_group_id: nil = a solo ask, which is born browsable and gets pooled.
      solo = RuleMavenWeb.GameLive.Show.recent_pairs_for_test(convo, nil)

      refute Enum.any?(solo, &(&1.q =~ "Dave")),
             "a screen-rejected crew question rode into a poolable solo ask's prompt"

      assert solo == []
    end

    test "but it IS still quoted back into its own crew, where the text already lives",
         ctx do
      rejected =
        group_question!(ctx.game, ctx.member, ctx.grp, %{
          cleaned_question: "Can Dave's rogue steal from Sarah's satchel?",
          question_normalized: true,
          browsable: false,
          pooled: false
        })

      convo = [
        %{
          id: rejected.id,
          role: :user,
          content: rejected.question,
          cleaned_question: rejected.cleaned_question,
          question_normalized: rejected.question_normalized,
          group_id: rejected.group_id,
          browsable: rejected.browsable
        },
        %{id: rejected.id, role: :assistant, content: rejected.answer}
      ]

      same_crew = RuleMavenWeb.GameLive.Show.recent_pairs_for_test(convo, ctx.grp.id)

      assert [%{q: "Can Dave's rogue steal from Sarah's satchel?"}] = same_crew
    end
  end
end
