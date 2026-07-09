defmodule RuleMavenWeb.RoleBadgeTest do
  @moduledoc """
  The badge is the only visible signal that a session is elevated, so it has to
  be right about who is what: "SA" for the owner, "A" for an ordinary admin,
  nothing at all for everyone else.
  """
  use RuleMaven.DataCase, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias RuleMaven.Users
  alias RuleMavenWeb.CoreComponents

  defp make(role) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        username: "rb#{n}",
        email: "rb#{n}@example.com",
        password: "password",
        role: "user"
      })

    case role do
      "user" -> user
      "admin" -> elem(Users.update_user_role(user, "admin"), 1)
      "super_admin" -> elem(Users.set_super_admin(user, true), 1)
    end
  end

  defp badge(user), do: render_component(&CoreComponents.role_badge/1, user: user)

  # The component renders the letters on their own line; compare the text, not
  # the surrounding whitespace.
  defp badge_text(html) do
    html |> String.replace(~r/<[^>]*>/, "") |> String.trim()
  end

  test "a super admin gets SA and the super variant class" do
    html = badge(make("super_admin"))

    assert badge_text(html) == "SA"
    assert html =~ "role-badge--super"
    assert html =~ "Super admin"
  end

  test "an ordinary admin gets A and no super variant" do
    html = badge(make("admin"))

    assert badge_text(html) == "A"
    refute html =~ "role-badge--super"
    refute html =~ "SA"
  end

  test "an ordinary user gets no badge at all" do
    html = badge(make("user"))

    refute html =~ "role-badge"
  end

  test "the badge never reads a role name directly — a nil user renders nothing" do
    assert render_component(&CoreComponents.role_badge/1, user: nil) |> String.trim() == ""
  end
end
