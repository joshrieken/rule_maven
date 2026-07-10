defmodule RuleMavenWeb.AdminLive.FlagsTargetingTest do
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

  test "granting a user by username adds an actor gate", %{conn: conn} do
    admin = user("admin")
    target = user("user")
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#grant-tool_quiz", %{"username" => target.username})
    |> render_submit()

    assert RuleMaven.Flags.enabled?(:tool_quiz, target)
    assert render(view) =~ target.username
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "unknown username flashes and writes nothing", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    html =
      view
      |> form("#grant-tool_quiz", %{"username" => "nobody_here"})
      |> render_submit()

    assert html =~ "No user named"
    assert RuleMaven.Flags.gates(:tool_quiz).actors == []
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "setting a percentage writes a percentage gate", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#pct-tool_quiz", %{"percentage" => "30"})
    |> render_submit()

    assert RuleMaven.Flags.gates(:tool_quiz).percentage == 0.3
  after
    FunWithFlags.clear(:tool_quiz)
  end
end
