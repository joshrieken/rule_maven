defmodule RuleMavenWeb.AdminLive.FlagsTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(role) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: role
      })

    u
  end

  test "renders flags grouped and toggles one", %{conn: conn} do
    {:ok, _} = RuleMaven.Flags.enable(:tool_quiz)
    admin = user("admin")

    {:ok, view, html} = conn |> login(admin) |> live(~p"/admin/flags")
    assert html =~ "Rules quiz"
    assert html =~ "tool_quiz"

    view |> element("button[phx-value-id=tool_quiz]") |> render_click()
    refute RuleMaven.Flags.enabled?(:tool_quiz, nil)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "non-admin is redirected", %{conn: conn} do
    u = user("user")
    assert {:error, {:redirect, %{to: "/"}}} = conn |> login(u) |> live(~p"/admin/flags")
  end
end
