defmodule RuleMavenWeb.GameLiveEmptySidebarTest do
  @moduledoc """
  With no threads and no community questions, the question sidebar renders an
  animated empty state (glyph + copy) rather than a bare line of text. Once a
  community question exists, the empty state is gone.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

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

  test "an empty question sidebar renders the animated empty state", %{conn: conn} do
    user = setup_user("empty_sidebar")
    game = published_game_fixture(%{name: "Quiet Game"})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "sidebar-empty"
    assert html =~ "sidebar-empty__glyph"
    assert html =~ "No questions yet"
    assert html =~ "it&#39;ll show up here." or html =~ "it'll show up here."
  end

  test "the empty state carries the animation hook classes the stylesheet targets",
       %{conn: conn} do
    user = setup_user("empty_sidebar_css")
    game = published_game_fixture(%{name: "Quiet Game 2"})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    css = File.read!(Path.join(File.cwd!(), "priv/static/assets/css/app.css"))

    for class <- ["sidebar-empty", "sidebar-empty__glyph", "sidebar-empty__title",
                  "sidebar-empty__hint"] do
      assert html =~ class, "#{class} missing from the rendered empty state"
      assert css =~ ".#{class}", "#{class} has no rule in app.css"
    end

    # The looping float must be disabled for users who ask for reduced motion.
    assert css =~ "prefers-reduced-motion"
    assert css =~ ~s([data-motion="off"] .sidebar-empty__glyph)
  end
end
