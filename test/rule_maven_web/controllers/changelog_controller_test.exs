defmodule RuleMavenWeb.ChangelogControllerTest do
  use RuleMavenWeb.ConnCase, async: true

  alias RuleMaven.{Changelog, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user!(name, role \\ "user") do
    {:ok, user} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  defp newest_version(admin?), do: hd(Changelog.visible_releases(admin?)).version

  test "renders What's new with the current version for signed-out visitors, no dot", %{
    conn: conn
  } do
    html = conn |> get(~p"/changelog") |> html_response(200)
    assert html =~ "What&#39;s new"
    assert html =~ "You're on Rule Maven v#{Changelog.app_version()}"
    assert html =~ ~s(id="header-version")
    refute html =~ "header-version-dot"
  end

  test "opening it marks the newest release as seen and clears the header dot", %{conn: conn} do
    user = create_user!("cl_page_user")

    # Elsewhere the header shows the dot (with screen-reader text) while unseen.
    home = conn |> login(user) |> get(~p"/help") |> html_response(200)
    assert home =~ "header-version-dot"
    assert home =~ "(updated: see what's new)"

    html = build_conn() |> login(user) |> get(~p"/changelog") |> html_response(200)
    refute html =~ "header-version-dot"
    assert Users.get_user(user.id).seen_version == newest_version(false)

    again = build_conn() |> login(user) |> get(~p"/help") |> html_response(200)
    refute again =~ "header-version-dot"
  end

  test "admins' notes are shown only to admins", %{conn: conn} do
    admin_notes? = Enum.any?(Changelog.releases(), &(&1.admins != []))

    user_html =
      conn |> login(create_user!("cl_plain2")) |> get(~p"/changelog") |> html_response(200)

    refute user_html =~ "For admins"

    admin_html =
      build_conn()
      |> login(create_user!("cl_admin2", "admin"))
      |> get(~p"/changelog")
      |> html_response(200)

    assert admin_html =~ "For admins" == admin_notes?
  end

  test "non-admins only see releases with notes for them", %{conn: conn} do
    html = conn |> login(create_user!("cl_plain3")) |> get(~p"/changelog") |> html_response(200)

    for r <- Changelog.releases() do
      shown? = html =~ "v#{r.version} <time"
      assert shown? == (r.everyone != []), "v#{r.version} shown?=#{shown?}"
    end
  end
end
