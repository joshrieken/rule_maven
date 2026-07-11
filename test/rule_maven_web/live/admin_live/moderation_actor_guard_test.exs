defmodule RuleMavenWeb.AdminLive.ModerationActorGuardTest do
  @moduledoc """
  A regular admin must not be able to force-logout, demote-answers,
  reset-reputation, or set-quota on a *peer* admin account — only a
  super admin may wield those levers against another admin.
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin(username) do
    {:ok, user} =
      Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

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

  test "regular admin cannot force-logout a peer admin", %{conn: conn} do
    actor = create_admin("mod_actor")
    target = create_admin("mod_target")

    {:ok, view, _html} = conn |> login(actor) |> live(~p"/admin/moderation")

    render_click(view, "force_logout", %{"id" => to_string(target.id)})

    assert render(view) =~ "can&#39;t moderate another admin"
    refute Users.get_user(target.id).sessions_valid_after
  end

  test "super admin can force-logout a regular admin", %{conn: conn} do
    actor = create_super_admin("mod_super")
    target = create_admin("mod_target2")

    {:ok, view, _html} = conn |> login(actor) |> live(~p"/admin/moderation")

    render_click(view, "force_logout", %{"id" => to_string(target.id)})

    assert render(view) =~ "Revoked all of"
    assert Users.get_user(target.id).sessions_valid_after
  end

  test "no admin, super or otherwise, can moderate a super admin", %{conn: conn} do
    actor = create_super_admin("mod_super2")
    target = create_super_admin("mod_super_target")

    {:ok, view, _html} = conn |> login(actor) |> live(~p"/admin/moderation")

    render_click(view, "force_logout", %{"id" => to_string(target.id)})

    assert render(view) =~ "Super admins can&#39;t be moderated"
    refute Users.get_user(target.id).sessions_valid_after
  end
end
