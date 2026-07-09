defmodule RuleMavenWeb.GameIndexDeleteAuthzTest do
  @moduledoc """
  The game index (`/`) lives in the :default live_session — logged in, but not admin. The
  delete menu item is hidden in the template for non-admins, which is not a
  guard: LiveView events are forgeable, and `confirm_delete` cascades the
  game's documents and questions.
  """
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import Ecto.Query

  alias RuleMaven.Games.Game
  alias RuleMaven.Repo

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_#{System.unique_integer([:positive])}",
            email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  test "a non-admin cannot delete a game by forging confirm_delete", %{conn: conn} do
    attacker = create_user("gi_attacker")
    game = published_game_fixture(%{name: "Precious Game"})

    conn = login(conn, attacker)
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "confirm_delete", %{"id" => to_string(game.id)})

    assert Repo.get(Game, game.id), "a non-admin must not be able to delete a game"
  end

  test "an admin can still delete a game", %{conn: conn} do
    admin = create_user("gi_admin", %{role: "admin"})
    game = published_game_fixture(%{name: "Doomed Game"})

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "confirm_delete", %{"id" => to_string(game.id)})

    refute Repo.get(Game, game.id)
  end

  test "a demoted admin on an open socket loses delete power", %{conn: conn} do
    admin = create_user("gi_demoted", %{role: "admin"})
    game = published_game_fixture(%{name: "Survivor Game"})

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/")

    # Role is re-fetched per event, not trusted from a mount-time assign.
    Repo.update_all(
      from(u in RuleMaven.Users.User, where: u.id == ^admin.id),
      set: [role: "user"]
    )

    render_click(view, "confirm_delete", %{"id" => to_string(game.id)})

    assert Repo.get(Game, game.id)
  end
end
