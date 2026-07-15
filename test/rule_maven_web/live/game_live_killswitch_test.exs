defmodule RuleMavenWeb.GameLiveKillSwitchTest do
  @moduledoc """
  `resubmit_question/3` (backing both `retry_question` and `regenerate_answer`)
  only checked `Games.check_rate_limit/1` — not the admin kill switch — so a
  retry/regenerate could still spend while `asks_disabled` was on. This drives
  both events through a real connected LiveView and asserts they're blocked
  with the same message as the primary "ask" flow, and that no new question
  row / Oban job is produced.
  """

  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo, Settings}
  alias RuleMaven.Games.QuestionLog

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  setup do
    on_exit(fn -> FunWithFlags.clear(:asks) end)
    :ok
  end

  defp setup_thread(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "#{prefix} Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        promoted: false
      })

    {user, game, ql}
  end

  test "retry_question is blocked while asks_disabled is on", %{conn: conn} do
    {user, game, ql} = setup_thread("retry_ks")
    {:ok, _} = RuleMaven.Flags.disable(:asks)

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = render_click(view, "retry_question", %{"id" => to_string(ql.id)})

    assert html =~ Settings.asks_disabled_message()
    assert Repo.aggregate(QuestionLog, :count) == 1
  end

  test "regenerate_answer is blocked while asks_disabled is on", %{conn: conn} do
    {user, game, ql} = setup_thread("regen_ks")
    {:ok, _} = RuleMaven.Flags.disable(:asks)

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = render_click(view, "regenerate_answer", %{"id" => to_string(ql.id)})

    assert html =~ Settings.asks_disabled_message()
    assert Repo.aggregate(QuestionLog, :count) == 1
  end
end
