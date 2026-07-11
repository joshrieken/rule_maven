defmodule RuleMavenWeb.AdminDbRedactionLiveTest do
  @moduledoc """
  `/admin/db` is the generic table console. A crew question/answer can name real
  people, so the console must never expose that prose to someone who isn't trusted
  with it. The primary control is the mount gate: the page is SUPERADMIN-only
  (RuleMavenWeb.AdminLive.Db is in `@superadmin_views`), so a plain admin can't
  reach it at all. The column-level default-deny masking in `Db.redact_sensitive/3`
  remains as defense-in-depth (unit-tested in AdminRawTextRedactionTest) in case
  that gate is ever loosened back to `:admin`.
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(name, role) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  test "a plain admin is denied the generic DB console" do
    conn = login(build_conn(), user("db_plain_admin", "admin"))

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/admin/db?table=questions_log")
  end

  test "a superadmin can open the console" do
    superadmin = user("db_superadmin", "admin")
    {:ok, superadmin} = RuleMaven.Users.set_super_admin(superadmin, true)

    conn = login(build_conn(), superadmin)

    assert {:ok, _view, _html} = live(conn, ~p"/admin/db?table=questions_log")
  end
end
