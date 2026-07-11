defmodule RuleMavenWeb.AdminLive.FlagsExperimentReadoutTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @exp :exp_ask_pipeline

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

  test "experiment row shows control/treatment counts", %{conn: conn} do
    admin = user("admin")
    subject = user("user")
    {:ok, _} = RuleMaven.Flags.grant_actor(@exp, subject)
    # treatment
    RuleMaven.Flags.variant(@exp, subject)
    # control
    RuleMaven.Flags.variant(@exp, user("user"))

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/flags")

    assert html =~ "control: 1"
    assert html =~ "treatment: 1"
  after
    FunWithFlags.clear(@exp)
  end
end
