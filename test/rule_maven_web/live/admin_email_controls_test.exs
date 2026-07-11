defmodule RuleMavenWeb.AdminEmailControlsTest do
  @moduledoc "Admin dashboard email controls: kill switch + sender address."

  use RuleMavenWeb.ConnCase, async: false

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

  defp create_super_admin do
    {:ok, user} =
      Users.create_user(%{
        username: "mail_super_admin",
        email: "mail_super_admin@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.set_super_admin(user, true)
    admin
  end

  test "email kill switch toggles from the dashboard", %{conn: conn} do
    on_exit(fn -> FunWithFlags.clear(:outbound_email) end)

    {:ok, view, html} = conn |> login(create_admin()) |> live(~p"/admin")

    assert html =~ "Email is on"

    view |> element("button[phx-click=toggle_email]") |> render_click()
    assert not RuleMaven.Flags.enabled?(:outbound_email)
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

  test "resend key saves, blank submit is a no-op, clear removes it", %{conn: conn} do
    on_exit(fn -> Settings.delete("resend_api_key") end)

    {:ok, view, html} = conn |> login(create_super_admin()) |> live(~p"/admin")

    assert html =~ "Resend key not set"

    view
    |> form("#resend-key-form", %{"resend_api_key" => "re_test_123"})
    |> render_submit()

    assert Settings.resend_api_key() == "re_test_123"
    assert render(view) =~ "Resend key: set."

    view
    |> form("#resend-key-form", %{"resend_api_key" => ""})
    |> render_submit()

    assert Settings.resend_api_key() == "re_test_123"

    view |> element("button[phx-click=clear_resend_key]") |> render_click()
    assert Settings.resend_api_key() == nil
    assert render(view) =~ "Resend key not set"
  end

  test "regular admin cannot see or submit the resend key form", %{conn: conn} do
    on_exit(fn -> Settings.delete("resend_api_key") end)

    {:ok, view, html} = conn |> login(create_admin()) |> live(~p"/admin")

    refute html =~ "resend-key-form"

    # Form isn't rendered for a regular admin; forge the event directly the
    # way a malicious client could, to prove the server-side gate holds too.
    result = render_submit(view, "save_resend_key", %{"resend_api_key" => "re_test_123"})

    assert result =~ "have permission"
    assert Settings.resend_api_key() == nil
  end
end
