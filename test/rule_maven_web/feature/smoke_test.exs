defmodule RuleMavenWeb.Feature.SmokeTest do
  use PhoenixTest.Playwright.Case, async: false

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  Browser-only smoke tests: things a real rendering engine must verify.
  Plain HTML-presence smoke tests live in test/rule_maven_web/smoke_flow_test.exs
  (ConnCase - milliseconds, no browser).
  """

  test "theme CSS custom properties are defined on :root", %{conn: conn} do
    conn
    |> visit("/login")
    |> evaluate(
      """
      () => {
        var styles = window.getComputedStyle(document.documentElement);
        var vars = ['--text', '--bg', '--accent', '--red', '--green'];
        for (var i = 0; i < vars.length; i++) {
          var v = styles.getPropertyValue(vars[i]).trim();
          if (!v) return false;
        }
        return true;
      }
      """,
      [is_function: true],
      fn has_vars ->
        assert has_vars,
               "expected :root CSS custom properties (--text, --bg, --accent, --red, --green) to be set"
      end
    )
  end

  test "page renders without fatal JavaScript errors", %{conn: conn} do
    # .phx-connected requires phoenix.js + live_view.js + app.js to have all
    # executed and the LiveSocket to have joined - a stronger "no fatal JS
    # crash" signal than the old body-exists check.
    user = create_user("smoke_js_user")
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)

    conn
    |> visit("/auto-login?token=#{token}")
    |> assert_has(".phx-connected")
  end

  defp create_user(username) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "testpassword123",
        role: "admin"
      })

    seen =
      Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})

    user
    |> Ecto.Changeset.change(tours_seen: seen)
    |> RuleMaven.Repo.update!()
  end
end
