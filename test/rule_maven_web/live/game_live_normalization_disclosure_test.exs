defmodule RuleMavenWeb.GameLiveNormalizationDisclosureTest do
  @moduledoc """
  When we rewrite (normalize) an asker's raw question, the chat bubble shows the
  normalized form as the main text plus a "You asked:" subline with the original
  wording, so the asker knows it was changed. The disclosure only renders for the
  asker (own questions) and admins — the main-chat query already scopes
  non-admins to their own rows. It stays hidden when raw and normalized match
  after case/whitespace folding.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp setup_user(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  defp view_html(conn, user, game, ql) do
    conn = login(conn, user)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    html
  end

  test "shows original wording when the question was normalized", %{conn: conn} do
    user = setup_user("norm_show")
    game = published_game_fixture(%{name: "Norm Show Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "how many cards do i draw",
        cleaned_question: "How many cards does a player draw per turn?",
        answer: "You draw two cards.",
        visibility: "private"
      })

    html = view_html(conn, user, game, ql)

    # Normalized form is the main bubble text.
    assert html =~ "How many cards does a player draw per turn?"
    # Original wording is disclosed under it.
    assert html =~ "You asked:"
    assert html =~ "how many cards do i draw"
  end

  test "hides the disclosure when raw and normalized match apart from case/space", %{conn: conn} do
    user = setup_user("norm_same")
    game = published_game_fixture(%{name: "Norm Same Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards does a player draw?",
        cleaned_question: "how many cards does a player draw?",
        answer: "You draw two cards.",
        visibility: "private"
      })

    html = view_html(conn, user, game, ql)

    refute html =~ "You asked:"
  end
end
