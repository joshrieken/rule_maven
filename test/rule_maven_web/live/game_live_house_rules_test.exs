defmodule RuleMavenWeb.GameLiveHouseRulesTest do
  @moduledoc """
  Task 6: the 🏠 House rules card on the game show page — add/edit/delete own
  rules, toggle visibility, see community rules, admin block, and the
  {:house_rule_checked, id} broadcast refreshing the verdict stamp.
  """

  # Not async: HouseRules.submit/3 starts a named `Oban` instance for
  # `Oban.insert/1` to target (Oban isn't supervised in test — see setup
  # below). Only GameLivePersonaDirectTest does this while async; everywhere
  # else (see test/rule_maven/house_rules_test.exs) follows the safer,
  # non-async convention so the shared process name never collides across
  # concurrently-running test modules.
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.HouseRules

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but HouseRules.submit/3 calls Oban.insert/1 (via HouseRuleCheckWorker),
  # which needs a named, configured instance to insert against.
  setup do
    start_supervised!({Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false})
    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  test "logged-in user adds a house rule and sees pending state", %{conn: conn} do
    user = create_user("hr_add")
    game = published_game_fixture(%{name: "House Rules Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # House rules live in a floating tool panel; open it before touching the form.
    render_click(view, "open_tool", %{"tool" => "house_rules"})
    render_click(view, "toggle_house_rule_form", %{})

    html =
      view
      |> form("#house-rule-form", house_rule: %{title: "No stacking", body: "Cards may not stack."})
      |> render_submit()

    assert html =~ "No stacking"
    assert html =~ "pending"

    [hr] = HouseRules.list_for_user(game.id, user.id)
    assert_enqueued worker: RuleMaven.Workers.HouseRuleCheckWorker, args: %{"house_rule_id" => hr.id}
  end

  test "owner can toggle visibility and delete", %{conn: conn} do
    user = create_user("hr_owner")
    game = published_game_fixture(%{name: "Owner Game"})

    {:ok, hr} =
      HouseRules.submit(user, game.id, %{"title" => "My rule", "body" => "Do this instead."})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "toggle_house_rule_visibility", %{"id" => hr.id})
    assert HouseRules.get(hr.id).visibility == "community"

    render_click(view, "toggle_house_rule_visibility", %{"id" => hr.id})
    assert HouseRules.get(hr.id).visibility == "private"

    html = render_click(view, "delete_house_rule", %{"id" => hr.id})
    refute html =~ "My rule"
    assert HouseRules.get(hr.id) == nil
  end

  test "owner can turn a rule off and back on", %{conn: conn} do
    user = create_user("hr_toggler")
    game = published_game_fixture(%{name: "Toggle Game"})

    {:ok, hr} =
      HouseRules.submit(user, game.id, %{"title" => "Switchable", "body" => "Do this instead."})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # The row lives inside the house-rules tool, which is closed at mount.
    html = render_click(view, "open_tool", %{"tool" => "house_rules"})
    assert html =~ ~s|data-testid="hr-enabled-toggle"|
    assert html =~ ~s|data-testid="hr-visibility-toggle"|
    assert html =~ "Private"
    assert HouseRules.get(hr.id).enabled == true

    render_click(view, "toggle_house_rule_enabled", %{"id" => hr.id})
    assert HouseRules.get(hr.id).enabled == false

    render_click(view, "toggle_house_rule_enabled", %{"id" => hr.id})
    assert HouseRules.get(hr.id).enabled == true
  end

  test "a stranger cannot toggle someone else's rule", %{conn: conn} do
    owner = create_user("hr_victim")
    stranger = create_user("hr_stranger")
    game = published_game_fixture(%{name: "Forge Game"})

    {:ok, hr} = HouseRules.submit(owner, game.id, %{"body" => "Owner's rule."})

    conn = login(conn, stranger)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # A forged phx-value-id naming the owner's rule must not flip it.
    render_click(view, "toggle_house_rule_enabled", %{"id" => hr.id})
    assert HouseRules.get(hr.id).enabled == true
  end

  # 768-dim unit basis vector — cosine similarity 1.0 with itself, so the rule
  # lands cleanly inside the overlay threshold against the question embedding.
  defp basis_vec, do: for(i <- 0..767, do: if(i == 0, do: 1.0, else: 0.0))

  defp overlay_setup(user, game) do
    {:ok, hr} = HouseRules.create(user, game.id, %{"title" => "Six cards", "body" => "We deal 6 cards."})

    {:ok, hr} =
      HouseRules.mark_checked(hr, %{
        verdict: "overrides",
        raw_quote: "Deal 5 cards to each player.",
        check_note: "Changes hand size.",
        citations: [],
        body_embedding: basis_vec()
      })

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards do I draw?",
        answer: "You draw 5 cards."
      })

    import Ecto.Query

    RuleMaven.Repo.update_all(
      from(q in RuleMaven.Games.QuestionLog, where: q.id == ^ql.id),
      set: [question_embedding: Pgvector.new(basis_vec())]
    )

    {hr, ql}
  end

  test "answer shows the house-rule overlay; delta button caches and renders the note", %{
    conn: conn
  } do
    user = create_user("hr_overlay")
    game = published_game_fixture(%{name: "Overlay Game"})
    {hr, ql} = overlay_setup(user, game)

    conn = login(conn, user)

    {:ok, view, html} =
      live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}")

    assert html =~ "Your house rule may change this"
    assert html =~ "Six cards"
    assert html =~ "How does this change the answer?"

    # Miss: enqueues the durable worker and shows the spinner.
    html = render_click(view, "house_rule_delta", %{"id" => hr.id})
    assert html =~ "hr-delta-pending"

    assert_enqueued(
      worker: RuleMaven.Workers.HouseRuleDeltaWorker,
      args: %{"house_rule_id" => hr.id, "question_log_id" => ql.id}
    )

    # Worker finishes: note cached, broadcast lands, spinner replaced by note.
    {:ok, _} = HouseRules.save_delta(hr, ql, "With your house rule, you draw 6 cards.")

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      "game:#{game.id}",
      {:house_rule_delta, hr.id, ql.id, :done}
    )

    html = render(view)
    assert html =~ "With your house rule, you draw 6 cards."
    refute html =~ "hr-delta-pending"

    # Cached note now renders instantly on a fresh load — no button, no worker.
    {:ok, _view, html2} =
      live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}")

    assert html2 =~ "With your house rule, you draw 6 cards."
  end

  test "no overlay when the near rule belongs to someone else", %{conn: conn} do
    user = create_user("hr_no_overlay")
    other = create_user("hr_no_overlay_other")
    game = published_game_fixture(%{name: "No Overlay Game"})

    # Rule belongs to `other`; the answered thread belongs to `user`.
    {:ok, hr} = HouseRules.create(other, game.id, %{"body" => "We deal 6 cards."})

    {:ok, _hr} =
      HouseRules.mark_checked(hr, %{
        verdict: "overrides",
        raw_quote: "Deal 5 cards.",
        check_note: "Changes hand size.",
        citations: [],
        body_embedding: basis_vec()
      })

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards do I draw?",
        answer: "You draw 5 cards."
      })

    import Ecto.Query

    RuleMaven.Repo.update_all(
      from(q in RuleMaven.Games.QuestionLog, where: q.id == ^ql.id),
      set: [question_embedding: Pgvector.new(basis_vec())]
    )

    conn = login(conn, user)

    {:ok, _view, html} =
      live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}")

    refute html =~ "Your house rule may change this"
  end

  test "community rules visible to other users, blocked ones hidden", %{conn: conn} do
    owner = create_user("hr_comm_owner")
    viewer = create_user("hr_comm_viewer")
    game = published_game_fixture(%{name: "Community Game"})

    {:ok, hr} =
      HouseRules.submit(owner, game.id, %{
        "title" => "Shared rule",
        "body" => "Everyone plays this way.",
        "visibility" => "community"
      })

    {:ok, blocked_hr} =
      HouseRules.submit(owner, game.id, %{
        "title" => "Blocked rule",
        "body" => "This one gets blocked.",
        "visibility" => "community"
      })

    {:ok, _} = HouseRules.set_blocked(blocked_hr, true)

    conn = login(conn, viewer)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = render_click(view, "open_tool", %{"tool" => "house_rules"})

    assert html =~ "Shared rule"
    refute html =~ "Blocked rule"
    _ = hr
  end

  test "non-owner mutating events are no-ops", %{conn: conn} do
    owner = create_user("hr_no_owner")
    other = create_user("hr_intruder")
    game = published_game_fixture(%{name: "Protected Game"})

    {:ok, hr} =
      HouseRules.submit(owner, game.id, %{
        "title" => "Protected rule",
        "body" => "Owner only.",
        "visibility" => "community"
      })

    conn = login(conn, other)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "open_tool", %{"tool" => "house_rules"})

    html = render_click(view, "delete_house_rule", %{"id" => hr.id})
    assert html =~ "Protected rule"
    assert HouseRules.get(hr.id) != nil

    render_click(view, "toggle_house_rule_visibility", %{"id" => hr.id})
    assert HouseRules.get(hr.id).visibility == "community"
  end

  test "house_rule_checked broadcast refreshes verdict stamp", %{conn: conn} do
    user = create_user("hr_broadcast")
    game = published_game_fixture(%{name: "Broadcast Game"})

    {:ok, hr} =
      HouseRules.submit(user, game.id, %{"title" => "Override rule", "body" => "We override this."})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "open_tool", %{"tool" => "house_rules"})

    {:ok, hr} =
      HouseRules.mark_checked(hr, %{
        verdict: "overrides",
        raw_quote: nil,
        check_note: nil,
        citations: []
      })

    send(view.pid, {:house_rule_checked, hr.id})

    assert render(view) =~ "Overrides RAW"
  end

  test "owner edits a house rule's body via the inline form", %{conn: conn} do
    user = create_user("hr_edit")
    game = published_game_fixture(%{name: "Edit Game"})

    {:ok, hr} =
      HouseRules.submit(user, game.id, %{"title" => "Old title", "body" => "Original body."})

    {:ok, hr} = HouseRules.mark_checked(hr, %{verdict: "matches", raw_quote: nil, check_note: nil, citations: []})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "open_tool", %{"tool" => "house_rules"})
    render_click(view, "start_edit_house_rule", %{"id" => hr.id})

    html =
      view
      |> form("form[phx-submit='edit_house_rule']",
        house_rule: %{title: "Old title", body: "New body text."}
      )
      |> render_submit()

    assert html =~ "New body text."

    updated = HouseRules.get(hr.id)
    assert updated.body == "New body text."
    assert updated.check_status == "pending"

    assert_enqueued worker: RuleMaven.Workers.HouseRuleCheckWorker, args: %{"house_rule_id" => hr.id}
  end

  test "owner re-checks a stale house rule", %{conn: conn} do
    user = create_user("hr_recheck")
    game = published_game_fixture(%{name: "Recheck Game"})

    {:ok, hr} =
      HouseRules.submit(user, game.id, %{"title" => "Rule", "body" => "Some body."})

    {:ok, hr} =
      HouseRules.mark_checked(hr, %{verdict: "matches", raw_quote: nil, check_note: nil, citations: []})

    HouseRules.mark_stale_for_game(game.id)
    hr = HouseRules.get(hr.id)
    assert hr.check_status == "stale"

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "recheck_house_rule", %{"id" => hr.id})

    assert HouseRules.get(hr.id).check_status == "pending"
    assert_enqueued worker: RuleMaven.Workers.HouseRuleCheckWorker, args: %{"house_rule_id" => hr.id}
  end

  test "admin sees block control; regular user doesn't", %{conn: conn} do
    owner = create_user("hr_block_owner")
    admin = create_user("hr_block_admin", %{role: "admin"})
    regular = create_user("hr_block_regular")
    game = published_game_fixture(%{name: "Block Game"})

    {:ok, _hr} =
      HouseRules.submit(owner, game.id, %{
        "title" => "Blockable rule",
        "body" => "Community visible.",
        "visibility" => "community"
      })

    admin_conn = login(conn, admin)
    {:ok, admin_view, _html} = live(admin_conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    admin_html = render_click(admin_view, "open_tool", %{"tool" => "house_rules"})
    assert admin_html =~ "block_house_rule"

    regular_conn = login(conn, regular)
    {:ok, regular_view, _html} = live(regular_conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    regular_html = render_click(regular_view, "open_tool", %{"tool" => "house_rules"})
    refute regular_html =~ "block_house_rule"
  end
end
