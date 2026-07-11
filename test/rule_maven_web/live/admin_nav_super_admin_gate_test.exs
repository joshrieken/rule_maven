defmodule RuleMavenWeb.AdminNavSuperAdminGateTest do
  @moduledoc """
  Header dropdown and mobile drawer must not link a regular admin to a page
  its own mount will bounce them out of. Companion to AdminNavCoverageTest,
  which asserts the super-admin side (every page IS linked for them).
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "gate_admin",
        email: "gate_admin@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  test "regular admin's nav omits super-admin-only pages", %{conn: conn} do
    {:ok, _lv, html} = login(conn, admin()) |> live(~p"/admin/health")

    for path <- ~w(/admin/llm /admin/bgg /admin/security /admin/flags) do
      refute html =~ ~s|href="#{path}"|, "#{path} should not be linked for a regular admin"
    end
  end
end
