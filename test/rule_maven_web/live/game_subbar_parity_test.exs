defmodule RuleMavenWeb.GameSubBarParityTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

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

  setup %{conn: conn} do
    game = published_game_fixture()
    admin = create_user("subbar_admin", %{role: "admin"})
    %{conn: login(conn, admin), game: game, admin: admin}
  end

  test "the game page patches to the overview; other pages navigate", %{conn: conn, game: game} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    # A patch link carries data-phx-link="patch"; a navigate link, "redirect".
    assert show_html =~ ~s(data-phx-link="patch")

    {:ok, _view, community_html} = live(conn, ~p"/games/#{game}/community")
    refute community_html =~ ~s(data-phx-link="patch")
    assert community_html =~ ~s(data-phx-link="redirect")
  end
end
