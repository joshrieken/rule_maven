defmodule RuleMavenWeb.AdminLive.IndexSuperAdminCardsTest do
  @moduledoc """
  The dashboard's card grid must reflect actual per-page access: a regular
  admin who can't get past the LLM/BGG/Security/Flags mount gate shouldn't
  see a card that dead-ends in a permission redirect.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(role) do
    {:ok, user} =
      Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    case role do
      "admin" ->
        {:ok, user} = Users.update_user_role(user, "admin")
        user

      "super_admin" ->
        {:ok, user} = Users.update_user_role(user, "admin")
        {:ok, user} = Users.set_super_admin(user, true)
        user
    end
  end

  test "regular admin does not see super-admin-only cards", %{conn: conn} do
    {:ok, _view, html} = conn |> login(create_user("admin")) |> live(~p"/admin")

    refute html =~ ~s|href="/admin/llm"|
    refute html =~ ~s|href="/admin/bgg"|
    refute html =~ ~s|href="/admin/security"|
    refute html =~ ~s|href="/admin/flags"|

    assert html =~ ~s|href="/admin/users"|
    assert html =~ ~s|href="/admin/embeddings"|
  end

  test "super admin sees every card", %{conn: conn} do
    {:ok, _view, html} = conn |> login(create_user("super_admin")) |> live(~p"/admin")

    assert html =~ ~s|href="/admin/llm"|
    assert html =~ ~s|href="/admin/bgg"|
    assert html =~ ~s|href="/admin/security"|
    assert html =~ ~s|href="/admin/flags"|
  end
end
