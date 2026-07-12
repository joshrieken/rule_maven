defmodule RuleMavenWeb.GameLive.AdminThreadWindowTest do
  @moduledoc """
  Admins used to load `limit: nil` in `question_group_opts/1` — every
  question ever asked for the game, unbounded. For a game with deep Q&A
  history this meant a multi-second query + preload + in-memory grouping
  cost on every mount and thread switch. These tests pin the bounded
  replacement: the default view is capped, an out-of-window `?t=` deep link
  is still recoverable, and admin search can still reach the full history.
  """

  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  defp make_admin(user) do
    {:ok, admin} = RuleMaven.Users.update_user_role(user, "admin")
    admin
  end

  # Seeds one question well outside the bounded window (oldest, community
  # visible so any viewer can see it) plus enough recent filler questions to
  # push it out of the default recent-N load.
  defp seed_deep_history(game, user, window) do
    oldest_time = DateTime.add(DateTime.utc_now(), -1000, :second) |> DateTime.truncate(:second)

    {:ok, oldest} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "What happens when the longest road tie needs breaking?",
        answer: "Longest Road stays with whoever already has it on a tie.",
        visibility: "community"
      })

    RuleMaven.Repo.update_all(
      from(q in RuleMaven.Games.QuestionLog, where: q.id == ^oldest.id),
      set: [inserted_at: oldest_time]
    )

    for n <- 1..window do
      {:ok, _} =
        RuleMaven.Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Filler question number #{n}?",
          answer: "Filler answer #{n}.",
          visibility: "community"
        })
    end

    oldest
  end

  test "admin default view is bounded, not the entire question history", %{conn: conn} do
    admin = create_user("bound_admin") |> make_admin()
    game = published_game_fixture(%{bgg_id: 501})
    _oldest = seed_deep_history(game, admin, 200)

    conn = login(conn, admin)
    {:ok, _lv, html} = live(conn, ~p"/games/#{game}")

    refute html =~ "longest road tie",
           "the oldest question, pushed out of the bounded window, should not be preloaded into every mount"

    assert html =~ "Filler question number 200"
  end

  test "an out-of-window ?t= deep link still resolves for an admin", %{conn: conn} do
    admin = create_user("deep_admin") |> make_admin()
    game = published_game_fixture(%{bgg_id: 502})
    oldest = seed_deep_history(game, admin, 200)

    conn = login(conn, admin)
    token = RuleMaven.Hashid.encode(oldest.id)
    {:ok, _lv, html} = live(conn, ~p"/games/#{game}?t=#{token}")

    assert html =~ "longest road tie"
  end

  test "admin search reaches beyond the bounded window into full history", %{conn: conn} do
    admin = create_user("search_admin") |> make_admin()
    game = published_game_fixture(%{bgg_id: 503})
    _oldest = seed_deep_history(game, admin, 200)

    conn = login(conn, admin)
    {:ok, lv, html} = live(conn, ~p"/games/#{game}")
    refute html =~ "longest road tie"

    html =
      lv
      |> form("form[phx-change='search']", query: "longest road tie")
      |> render_change()

    assert html =~ "longest road tie"
  end

  test "a non-admin's out-of-window ?t= link to another user's private question stays denied", %{
    conn: conn
  } do
    owner = create_user("priv_owner")
    other = create_user("priv_other")
    game = published_game_fixture(%{bgg_id: 504})

    {:ok, private_q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "Owner's private question, never shared",
        answer: "answer",
        visibility: "private"
      })

    conn = login(conn, other)
    token = RuleMaven.Hashid.encode(private_q.id)
    {:ok, _lv, html} = live(conn, ~p"/games/#{game}?t=#{token}")

    refute html =~ "Owner's private question"
  end
end
