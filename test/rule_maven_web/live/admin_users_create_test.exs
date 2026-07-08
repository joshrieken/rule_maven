defmodule RuleMavenWeb.AdminUsersCreateTest do
  @moduledoc """
  Admin > Manage Users: creating a user from the form.

  The create inputs must live in a real <form> — LiveView only emits
  phx-change/phx-submit for form elements, so a div-bound phx-change never
  fires in a browser and the Create button stays disabled forever.
  """

  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin do
    {:ok, user} =
      Users.create_user(%{
        username: "boss_admin",
        email: "boss_admin@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "create form is a real form element (phx-change on div never fires)", %{conn: conn} do
    {:ok, view, _html} = conn |> login(create_admin()) |> live(~p"/admin/users")

    assert has_element?(view, "form[phx-submit=create_user]"),
           "create-user inputs must be inside a <form phx-submit>; " <>
             "phx-change on a div is never triggered by the browser"
  end

  test "submitting the form creates the user and shows a temp password", %{conn: conn} do
    {:ok, view, _html} = conn |> login(create_admin()) |> live(~p"/admin/users")

    view
    |> form("form[phx-submit=create_user]", %{
      "new_username" => "fresh_user",
      "new_email" => "fresh@test.com",
      "new_role" => "user"
    })
    |> render_submit()

    assert Users.get_user_by_username("fresh_user")
    assert render(view) =~ "Account created"
  end
end
