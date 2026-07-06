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
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

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
    {:ok, _view, admin_html} = live(admin_conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    assert admin_html =~ "block_house_rule"

    regular_conn = login(conn, regular)
    {:ok, _view, regular_html} = live(regular_conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    refute regular_html =~ "block_house_rule"
  end
end
