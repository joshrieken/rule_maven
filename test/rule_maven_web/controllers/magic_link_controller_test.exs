defmodule RuleMavenWeb.MagicLinkControllerTest do
  use RuleMavenWeb.ConnCase, async: true

  alias RuleMaven.Users

  defp user_fixture do
    {:ok, u} =
      Users.create_user(%{
        username: "linkctl",
        email: "link.ctl@test.com",
        password: "oldpass1234"
      })

    u
  end

  test "GET /magic-link renders the request form", %{conn: conn} do
    conn = get(conn, ~p"/magic-link")
    assert html_response(conn, 200) =~ "Email me a sign-in link"
  end

  test "POST /magic-link always reports success and logs the user in via the emailed link", %{
    conn: conn
  } do
    user = user_fixture()

    conn = post(conn, ~p"/magic-link", magic_link: %{"email" => "link.ctl@test.com"})
    assert html_response(conn, 200) =~ "sign-in link is on its way"

    assert_receive {:email, email}, 1000
    [_, token] = Regex.run(~r{/magic-link/(\S+)}, email.text_body)

    conn = build_conn() |> get(~p"/magic-link/#{token}")
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
  end

  test "unknown email still renders the generic success message", %{conn: conn} do
    conn = post(conn, ~p"/magic-link", magic_link: %{"email" => "nobody@nowhere.com"})
    assert html_response(conn, 200) =~ "sign-in link is on its way"
  end

  test "an invalid token redirects back with an error", %{conn: conn} do
    conn = get(conn, ~p"/magic-link/not-a-real-token")
    assert redirected_to(conn) == ~p"/magic-link"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
  end
end
