defmodule RuleMavenWeb.AdminLive.FlagsExperimentReadoutTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @exp :exp_ask_pipeline

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(role) do
    create_role = if role == "super_admin", do: "admin", else: role

    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: create_role
      })

    if role == "super_admin" do
      {:ok, u} = RuleMaven.Users.set_super_admin(u, true)
      u
    else
      u
    end
  end

  test "experiment row shows control/treatment counts", %{conn: conn} do
    super_admin = user("super_admin")
    subject = user("user")
    {:ok, _} = RuleMaven.Flags.grant_actor(@exp, subject)
    # treatment
    RuleMaven.Flags.variant(@exp, subject)
    # control
    RuleMaven.Flags.variant(@exp, user("user"))

    {:ok, _view, html} = conn |> login(super_admin) |> live(~p"/admin/flags")

    assert html =~ "control: 1"
    assert html =~ "treatment: 1"
  after
    FunWithFlags.clear(@exp)
  end
end
