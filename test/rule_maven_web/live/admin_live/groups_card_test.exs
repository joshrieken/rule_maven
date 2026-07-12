defmodule RuleMavenWeb.AdminLive.GroupsCardTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin(prefix) do
    {:ok, user} =
      Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "the admin dashboard links to /admin/groups", %{conn: conn} do
    admin = create_admin("idxcard")

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

    assert html =~ ~s(href="/admin/groups")
  end
end
