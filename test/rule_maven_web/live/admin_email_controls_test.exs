defmodule RuleMavenWeb.AdminEmailControlsTest do
  @moduledoc "Admin dashboard email controls: kill switch + sender address."

  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.{Settings, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin do
    {:ok, user} =
      Users.create_user(%{
        username: "mail_admin",
        email: "mail_admin@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "email kill switch toggles from the dashboard", %{conn: conn} do
    {:ok, view, html} = conn |> login(create_admin()) |> live(~p"/admin")

    assert html =~ "Email is on"

    view |> element("button[phx-click=toggle_email]") |> render_click()
    assert Settings.email_disabled?()
    assert render(view) =~ "Email is paused"
  end

  test "sender address saves and rejects junk", %{conn: conn} do
    {:ok, view, _html} = conn |> login(create_admin()) |> live(~p"/admin")

    view
    |> form("#mail-from-form", %{"mail_from" => "hello@rulemaven.app"})
    |> render_submit()

    assert Settings.mail_from() == "hello@rulemaven.app"

    view
    |> form("#mail-from-form", %{"mail_from" => "not-an-email"})
    |> render_submit()

    assert Settings.mail_from() == "hello@rulemaven.app"
  end
end
