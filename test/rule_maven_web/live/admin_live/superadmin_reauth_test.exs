defmodule RuleMavenWeb.AdminLive.SuperadminReauthTest do
  @moduledoc """
  A super_admin's open LiveView socket on a superadmin-only page (LLM
  Provider, BGG, Security, Flags, Embeddings, Prompts, Automation, DB Admin)
  must lose mutating access the moment they're demoted mid-session, same as
  the existing :admin_reauth guarantee for plain admin pages.
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RuleMaven.{Repo, Users}
  alias RuleMaven.Users.User

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_super_admin(username) do
    {:ok, user} =
      Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.set_super_admin(user, true)
    admin
  end

  test "demoted super_admin can't keep firing events on the LLM Provider page", %{conn: conn} do
    actor = create_super_admin("reauth_super")

    {:ok, view, _html} = conn |> login(actor) |> live(~p"/admin/llm")

    # Demote super_admin -> admin (NOT all the way to plain user) mid-session
    # — the socket stays open, mirroring what a real demote from another tab
    # would do. `Users.set_super_admin/2` demotes to "user", which the OLD
    # blanket :admin reauth check would already catch; going only as far as
    # "admin" isolates the actual gap this fix closes.
    {:ok, _} = actor |> User.elevation_changeset("admin") |> Repo.update()

    assert {:error, {:redirect, %{to: "/"}}} =
             render_click(view, "select_provider", %{"llm_provider" => "groq"})
  end

  test "still-standing super_admin keeps working on the LLM Provider page", %{conn: conn} do
    actor = create_super_admin("reauth_super_ok")

    {:ok, view, _html} = conn |> login(actor) |> live(~p"/admin/llm")

    html = render_click(view, "select_provider", %{"llm_provider" => "groq"})
    assert html =~ ~s(value="groq" selected)
  end
end
