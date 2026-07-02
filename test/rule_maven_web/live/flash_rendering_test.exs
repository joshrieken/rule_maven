defmodule RuleMavenWeb.FlashRenderingTest do
  @moduledoc """
  Regression test for flash messages never rendering on connected LiveViews.

  `put_flash` in a LiveView only updates the socket assign; without a live
  layout that renders `flash_group`, nothing in the DOM ever shows it (the
  root layout's own flash_group is part of the dead render and never
  re-renders after the WebSocket connects). This test drives a real
  `put_flash` call through a LiveView event and asserts the message shows up
  in `render(view)` — i.e. in the *live*, post-connect render, not just the
  initial HTML.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  test "put_flash in a connected LiveView renders in the live DOM", %{conn: conn} do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "flash_test_user",
        email: "flash_test_user@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "Flash Test Game"})

    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}")

    # Not present before the event fires.
    refute html =~ "Please ask a complete question."

    view
    |> element("form[phx-submit=\"ask\"]")
    |> render_submit(%{"question" => "hi"})

    assert render(view) =~ "Please ask a complete question."
  end

  test "controller-rendered flash still renders (e.g. invalid password-reset token)", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/reset-password/bogus-token", %{
        "reset" => %{"password" => "newpassword1234", "password_confirmation" => "newpassword1234"}
      })

    assert redirected_to(conn) == ~p"/reset-password"

    conn = get(recycle(conn), ~p"/reset-password")
    assert html_response(conn, 200) =~ "That reset link is invalid or has expired."
  end
end
