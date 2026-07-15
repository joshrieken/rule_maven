defmodule RuleMavenWeb.GameLiveGroupPrivacyTest do
  @moduledoc """
  A group row's RAW question text (the asker's verbatim prose) must never render
  on /games/:id for anyone outside the group — not in the sidebar thread list,
  and not in the "↳ You asked:" disclosure, which prints `original_question`
  verbatim.

  The reachable path is not exotic: a group row is pooled by design, and the
  Helpful thumb on a pool hit targets the pool SOURCE row — so an ordinary user
  who upvotes a served answer ends up holding an upvote on a group member's row.
  """
  # async: false — the removed-member test starts a globally-named Oban instance
  # (the ask form enqueues an AskWorker job), same as the other ask-form LiveView
  # tests.
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Games.QuestionVote

  @raw "SECRETWORDING will Dave's smuggler get caught"

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user!(prefix, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_#{n}",
            email: "#{prefix}_#{n}@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  defp group_row!(game, member, group, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: member.id,
            group_id: group.id,
            question: @raw,
            cleaned_question: "Can a smuggler be caught?",
            answer: "Yes, on a failed roll.",
            visibility: "private",
            citation_valid: true,
            pooled: true,
            browsable: false,
            # Stands in for a row the normalize step actually rewrote — the premise
            # the whole gate rests on, and what makes `cleaned_question` a scrub
            # rather than the asker's verbatim prose under a scrubbed column's name.
            question_normalized: true
          },
          attrs
        )
      )

    q
  end

  setup do
    # published_game_fixture — a not-yet-Ready game renders a "not ready" stub
    # with no Q&A UI at all, which would make every negative assertion vacuous.
    game = published_game_fixture(%{name: "Crew Game"})
    member = user!("crew_member")
    outsider = user!("crew_outsider")
    group = group_fixture(member)

    %{game: game, member: member, outsider: outsider, group: group}
  end

  test "a group row upvoted by a non-member never shows its raw text", ctx do
    q = group_row!(ctx.game, ctx.member, ctx.group, %{})

    Repo.insert!(%QuestionVote{
      question_log_id: q.id,
      user_id: ctx.outsider.id,
      value: "up",
      weight: 1.0
    })

    conn = login(build_conn(), ctx.outsider)
    {:ok, view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}")

    refute html =~ "SECRETWORDING"
    refute html =~ "Can a smuggler be caught?"

    # And the thread isn't even openable from this account.
    refute render(view) =~ "SECRETWORDING"
  end

  test "a skip_normalize group row (raw text is its only text) never shows it", ctx do
    # On the "Ask exactly this" path cleaned_question and canonical_question are
    # both nil, so display_question/1 itself falls back to the raw column — the
    # sidebar title would BE the user's verbatim prose.
    q =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        cleaned_question: nil,
        canonical_question: nil
      })

    Repo.insert!(%QuestionVote{
      question_log_id: q.id,
      user_id: ctx.outsider.id,
      value: "up",
      weight: 1.0
    })

    conn = login(build_conn(), ctx.outsider)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}")

    refute html =~ "SECRETWORDING"
  end

  test "the asker still sees their own raw wording in the disclosure", ctx do
    q = group_row!(ctx.game, ctx.member, ctx.group, %{})

    conn = login(build_conn(), ctx.member)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    # The disclosure lives on the full-question sheet now (tap the pinned
    # question); the raw wording is still the asker's to see there.
    assert view |> element("button.qa-question__text") |> render_click() =~ "SECRETWORDING"
  end

  test "an admin does NOT see another user's raw wording in the disclosure", ctx do
    # Admins legitimately see every row in the main chat (question_group_opts/1),
    # but the disclosure prints the verbatim prose — nobody but the asker gets it.
    q = group_row!(ctx.game, ctx.member, ctx.group, %{})
    admin = user!("crew_admin", %{role: "admin"})

    conn = login(build_conn(), admin)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    refute html =~ "SECRETWORDING"
    # The scrubbed text is what an admin sees.
    assert html =~ "Can a smuggler be caught?"
  end

  test "an admin does NOT see another user's raw crew ANSWER in the bubble", ctx do
    # The twin of the question leak: an admin's thread carries every user's rows,
    # the question is scrubbed to "(question withheld)"/cleaned — and then the
    # answer bubble one line below restated the crew member's private question
    # ("Yes, SECRETANSWER…"), handing back the very wording the scrub removed.
    q =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        answer: "Yes, SECRETANSWER on a failed roll."
      })

    admin = user!("ans_admin", %{role: "admin"})
    conn = login(build_conn(), admin)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    refute html =~ "SECRETANSWER"
    assert html =~ "(answer withheld)"
  end

  test "an admin does NOT see the crew answer via the persona-voice overlay", ctx do
    # The styled answer is the same private prose in a costume, and the Voices
    # cache is keyed only by (question_log_id, voice) with no authz — so a styled
    # copy sitting there (the asker's own restyle, or the old crew store_direct)
    # let the admin's persona overlay render around the "(answer withheld)" gate.
    q =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        answer: "Yes, SECRETANSWER on a failed roll."
      })

    :ok = RuleMaven.Voices.store_direct(q.id, "pirate", "Arr, PIRATESECRET be the ruling.")

    admin = user!("voice_admin", %{role: "admin"})
    conn = login(build_conn(), admin)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    # Admin picks the persona whose styled copy is already in the shared store.
    html = render_click(view, "set_voice", %{"voice" => "pirate"})

    refute html =~ "PIRATESECRET", "the persona overlay leaked the withheld crew answer"
    refute html =~ "SECRETANSWER"
    assert html =~ "(answer withheld)"
  end

  test "the audit-trail modal's version history does NOT reveal a withheld crew answer", ctx do
    # The modal's "Version history" section prints prior versions' `metadata["answer"]`
    # (the raw snapshot delete_question writes). A crew answer restates the private
    # question, so it must be withheld for a row the admin can't see live (not their
    # own, not browsable) — the same `user_id == self OR browsable` gate the bubble uses.
    live_row =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        cleaned_question: "Can a smuggler cheat?",
        answer: "No."
      })

    # A prior version of the same crew thread, deleted → snapshotted to the audit
    # log with its raw answer. chain_walk matches it to live_row by shared text.
    prior =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        cleaned_question: "Can a smuggler cheat?",
        answer: "No, HISTORYSECRET, the smuggler is caught."
      })

    {:ok, _} = RuleMaven.Games.delete_question(prior, ctx.member)

    admin = user!("hist_admin", %{role: "admin"})
    conn = login(build_conn(), admin)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(live_row.id)}"
      )

    html = render_click(view, "open_audit", %{"id" => to_string(live_row.id)})

    refute html =~ "HISTORYSECRET", "the audit-trail version history leaked a withheld crew answer"
  end

  test "the audit-trail modal's version history shows prior versions for a visible row", ctx do
    # A browsable crew row's answer is public, so the modal may surface its prior
    # versions — the flip side of the withholding gate above.
    live_row =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        cleaned_question: "How many cards?",
        answer: "Seven.",
        browsable: true
      })

    prior =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        cleaned_question: "How many cards?",
        answer: "Six, HISTORYSHOWN, was the old ruling.",
        browsable: true,
        verdict: "legal",
        llm_model: "HISTORYMODEL-9"
      })

    {:ok, _} = RuleMaven.Games.delete_question(prior, ctx.member)

    admin = user!("hist_show_admin", %{role: "admin"})
    conn = login(build_conn(), admin)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(live_row.id)}"
      )

    html = render_click(view, "open_audit", %{"id" => to_string(live_row.id)})

    assert html =~ "HISTORYSHOWN", "the audit-trail version history dropped a prior version's answer"
    # The full field snapshot round-trips into the version's own stat sections.
    assert html =~ "HISTORYMODEL-9", "the version panel dropped a snapshotted stat (model)"
  end

  test "the asker still sees their own crew ANSWER in the bubble", ctx do
    q =
      group_row!(ctx.game, ctx.member, ctx.group, %{
        answer: "Yes, SECRETANSWER on a failed roll."
      })

    conn = login(build_conn(), ctx.member)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    assert html =~ "SECRETANSWER"
  end

  test "a forged community_vote id the page never rendered is ignored", ctx do
    q = group_row!(ctx.game, ctx.member, ctx.group, %{browsable: true})

    conn = login(build_conn(), ctx.outsider)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}")

    render_hook(view, "community_vote", %{"id" => to_string(q.id), "vote" => "up"})

    assert Repo.aggregate(QuestionVote, :count) == 0
  end

  test "an admin does NOT get the raw wording via the live :ask_complete broadcast", ctx do
    # The static render was already gated by own_raw_question/2, but the
    # :ask_complete handler re-put `original_question` straight from the row —
    # so an admin watching a crew member's still-"Thinking…" thread got the
    # verbatim prose pushed to them the moment the answer landed.
    q = group_row!(ctx.game, ctx.member, ctx.group, %{answer: "Thinking..."})
    admin = user!("bcast_admin", %{role: "admin"})

    {:ok, view, _html} =
      live(
        login(build_conn(), admin),
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    {:ok, answered} = Games.log_question_update(q, %{answer: "Yes, on a failed roll."})

    RuleMaven.Workers.AskWorker.broadcast_complete(answered, %{
      faq_hit: false,
      pool_hit: false,
      tier: nil,
      verified: false,
      followups: [],
      also_asked: []
    })

    html = render(view)

    refute html =~ "SECRETWORDING"
    assert html =~ "Can a smuggler be caught?"
  end

  test "the asker DOES get their own raw wording via :ask_complete", ctx do
    q = group_row!(ctx.game, ctx.member, ctx.group, %{answer: "Thinking..."})

    {:ok, view, _html} =
      live(
        login(build_conn(), ctx.member),
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    {:ok, answered} = Games.log_question_update(q, %{answer: "Yes, on a failed roll."})

    RuleMaven.Workers.AskWorker.broadcast_complete(answered, %{
      faq_hit: false,
      pool_hit: false,
      tier: nil,
      verified: false,
      followups: [],
      also_asked: []
    })

    assert view |> element("button.qa-question__text") |> render_click() =~ "SECRETWORDING"
  end

  test "a removed member stops seeing the crew feed and stops writing into it", ctx do
    # Membership used to be checked only at mount and at set_active_group, so a
    # member removed mid-session kept a socket that both READ the crew feed on
    # every :ask_complete and WROTE into it (the next ask still carried group_id).
    #
    # Submitting the ask form enqueues an AskWorker job, and Oban is unsupervised
    # in test (`testing: :manual`) — same queueless instance the other ask-form
    # LiveView tests start.
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    {:ok, _} = RuleMaven.Groups.join_by_code(ctx.outsider, ctx.group.invite_code)
    conn = login(build_conn(), ctx.outsider)

    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}")

    view
    |> element("[phx-value-group='#{Phoenix.Param.to_param(ctx.group)}']")
    |> render_click()

    assert render(view) =~ ctx.group.name

    {:ok, _} = RuleMaven.Groups.remove_member(ctx.member, ctx.group, ctx.outsider.id)

    view
    |> form("#ask-form", %{"question" => "what happens when I get caught?"})
    |> render_submit()

    row =
      RuleMaven.Games.QuestionLog
      |> Repo.get_by(question: "what happens when I get caught?")

    assert row, "the ask was still logged"
    assert is_nil(row.group_id), "a removed member's ask was still stamped with the crew"
  end

  test "Ask exactly this cannot launder a crew question into the public pool", ctx do
    # The laundering path: the re-ask took its TEXT from the old crew row but its
    # group_id from the socket's CURRENT context. Once the asker has LEFT the crew
    # the group_id cannot be carried across at all, so the new row lands
    # group_id: nil while still carrying the crew's raw, never-screened wording.
    #
    # The crew is owned by someone else here precisely so the asker can be removed
    # from it — that is what makes group_id un-carryable and arms the bug.
    crew = group_fixture(ctx.outsider)
    {:ok, _} = RuleMaven.Groups.join_by_code(ctx.member, crew.invite_code)

    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    q = group_row!(ctx.game, ctx.member, crew, %{})

    {:ok, _} = RuleMaven.Groups.remove_member(ctx.outsider, crew, ctx.member.id)

    {:ok, view, _html} =
      live(
        login(build_conn(), ctx.member),
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    render_click(view, "ask_exactly", %{"id" => to_string(q.id)})

    reasked =
      RuleMaven.Games.QuestionLog
      |> Repo.get_by(question: @raw, answer: "Thinking...")

    assert reasked, "precondition: the verbatim re-ask row was created"
    assert is_nil(reasked.group_id), "precondition: the crew could not be carried across"

    refute reasked.browsable,
           "a re-ask carrying the crew's raw wording was inserted as browsable"

    # Asserting on the "Thinking..." row is NOT enough, and an earlier version of
    # this test made exactly that mistake: AskWorker rewrites `browsable` when the
    # answer lands, and its unconditional `browsable: is_nil(group_id)` re-opened
    # the row moments later — the insert-time gate above passed while the shipped
    # behaviour still published the crew's raw wording. Run the worker.
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "Yes, on a failed roll.", finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    RuleMaven.Workers.AskWorker.perform(%Oban.Job{
      id: nil,
      args: %{
        "game_id" => ctx.game.id,
        "question_log_id" => reasked.id,
        "question" => reasked.question,
        "user_id" => ctx.member.id,
        "skip_normalize" => true,
        "skip_pool" => true
      }
    })

    answered = Repo.get(RuleMaven.Games.QuestionLog, reasked.id)

    refute answered.browsable,
           "AskWorker re-opened the laundered row when the answer landed"

    assert QuestionLog.listed_question(answered) == "(question withheld)"
  end

  test "a CLEARED crew row's raw wording still cannot be re-asked into the pool", ctx do
    # browsable: true means the screen passed the row's SCRUBBED text. The raw
    # column is precisely what the scrub removed — so inheriting `browsable` from
    # the source row (rather than its crew provenance) would wave through exactly
    # the wording a screen has already judged unsafe to publish.
    crew = group_fixture(ctx.outsider)
    {:ok, _} = RuleMaven.Groups.join_by_code(ctx.member, crew.invite_code)

    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    q = group_row!(ctx.game, ctx.member, crew, %{browsable: true})

    {:ok, _} = RuleMaven.Groups.remove_member(ctx.outsider, crew, ctx.member.id)

    {:ok, view, _html} =
      live(
        login(build_conn(), ctx.member),
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    render_click(view, "ask_exactly", %{"id" => to_string(q.id)})

    reasked = Repo.get_by(RuleMaven.Games.QuestionLog, question: @raw, answer: "Thinking...")

    assert reasked
    assert is_nil(reasked.group_id), "precondition: the crew could not be carried across"

    refute reasked.browsable,
           "the raw wording behind a CLEARED crew row was published verbatim"
  end

  describe "the other columns that carry the asker's words" do
    # `also_asked` is a SECOND copy of the raw question — the answer prompt asks the
    # model for "the exact text of the additional questions". It lives outside the
    # question/cleaned/canonical triad that every gate mediates, and the conversation
    # rendered it as "Related questions" chips to anyone who could open the row.
    #
    # Note the fixtures in the rest of this file all set `also_asked: []`, which is
    # exactly why six rounds of review walked past this.
    @secret_also "and does the Persephone house rule about turn order break the endgame?"

    test "a stranger who upvoted the pooled answer does not see the crew's also_asked",
         ctx do
      # A CLEARED crew row (the publish screen passed its scrubbed primary text), so
      # it is legitimately listable — this is the state where the leak was live.
      q =
        group_row!(ctx.game, ctx.member, ctx.group, %{
          browsable: true,
          also_asked: [@secret_also],
          followups: ["Can the Persephone smuggler be searched twice?"]
        })

      stranger = user!("stranger")
      Games.set_community_vote(q.id, stranger.id, "up", false)

      {:ok, view, _html} =
        live(
          login(build_conn(), stranger),
          ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
        )

      html = render(view)

      refute html =~ "Persephone house rule",
             "a stranger read the crew's raw secondary question from also_asked"

      refute html =~ "SECRETWORDING"
    end

    test "an admin does not see the crew's also_asked, followups, or raw_response", ctx do
      admin = user!("aa_admin", %{role: "admin"})

      q =
        group_row!(ctx.game, ctx.member, ctx.group, %{
          also_asked: [@secret_also],
          followups: ["Can the Persephone smuggler be searched twice?"],
          raw_response: ~s({"answer":"Yes.","also_asked":["#{@secret_also}"]})
        })

      {:ok, view, _html} =
        live(
          login(build_conn(), admin),
          ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
        )

      html = render(view)

      # An admin's thread list carries every user's rows, which is precisely why
      # shown_question/2 already routes them through listed_question/1. The same
      # rule has to hold for every other column that carries the asker's words —
      # including raw_response, which is the model's full JSON envelope and holds
      # a verbatim copy of also_asked.
      refute html =~ "Persephone house rule",
             "an admin read the crew's raw secondary question"

      refute html =~ "searched twice",
             "an admin read followups derived from the crew's unscreened question"
    end

    test "the asker still sees their own also_asked and followups", ctx do
      q =
        group_row!(ctx.game, ctx.member, ctx.group, %{
          also_asked: [@secret_also],
          followups: ["Can the Persephone smuggler be searched twice?"]
        })

      {:ok, view, _html} =
        live(
          login(build_conn(), ctx.member),
          ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
        )

      html = render(view)

      assert html =~ "Persephone house rule", "the asker lost their own related questions"
      assert html =~ "searched twice"
    end
  end
end
