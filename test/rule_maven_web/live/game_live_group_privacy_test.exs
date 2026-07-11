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
            browsable: false
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

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(ctx.game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    assert html =~ "SECRETWORDING"
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

    assert render(view) =~ "SECRETWORDING"
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
end
