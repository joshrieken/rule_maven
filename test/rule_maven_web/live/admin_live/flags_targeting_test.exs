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

  test "forged percentage >= 100 is rejected instead of crashing", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    html =
      view
      |> form("#pct-tool_quiz", %{"percentage" => "150"})
      |> render_submit()

    assert html =~ "Invalid percentage."
    assert RuleMaven.Flags.gates(:tool_quiz).percentage == nil
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "forged non-numeric percentage is rejected instead of crashing", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    html =
      view
      |> form("#pct-tool_quiz", %{"percentage" => "not-a-number"})
      |> render_submit()

    assert html =~ "Invalid percentage."
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "forged non-numeric revoke user-id is a no-op instead of crashing", %{conn: conn} do
    admin = user("admin")
    target = user("user")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#grant-tool_quiz", %{"username" => target.username})
    |> render_submit()

    assert view
           |> element("button[phx-value-flag=tool_quiz][phx-value-user-id='#{target.id}']")
           |> render_click(%{"user-id" => "not-a-number"}) =~ target.username

    assert RuleMaven.Flags.enabled?(:tool_quiz, target)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "phx-value-id uniquely identifies the toggle even with an actor grant and a percentage set",
       %{conn: conn} do
    admin = user("admin")
    target = user("user")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#grant-tool_quiz", %{"username" => target.username})
    |> render_submit()

    view
    |> form("#pct-tool_quiz", %{"percentage" => "30"})
    |> render_submit()

    assert view |> has_element?("button[phx-value-id=tool_quiz]")

    was_on = RuleMaven.Flags.enabled?(:tool_quiz, nil)

    view
    |> element("button[phx-value-id=tool_quiz]")
    |> render_click()

    assert RuleMaven.Flags.enabled?(:tool_quiz, nil) == not was_on

    assert view
           |> has_element?("button[phx-value-flag=tool_quiz][phx-value-user-id='#{target.id}']")

    view
    |> element("button[phx-value-flag=tool_quiz][phx-value-user-id='#{target.id}']")
    |> render_click()

    # Assert on the gate directly rather than `enabled?/2`: a percentage gate is
    # still active (30%), so `enabled?/2` can randomly return true for this user
    # by percentage bucketing even with the actor gate cleared.
    refute "user:#{target.id}" in RuleMaven.Flags.gates(:tool_quiz).actors
  after
    FunWithFlags.clear(:tool_quiz)
  end
end
