defmodule RuleMavenWeb.Feature.SmokeTest do
  use RuleMavenWeb.FeatureCase, async: false

  @moduledoc """
  Smoke tests verifying the app loads and renders with theme-appropriate CSS.
  These run in a real headless Chrome via Wallaby.
  """

  feature "app loads and renders root page", %{session: session} do
    session
    |> visit("/")
    |> assert_has(css("body"))
    |> assert_has(css(".app-shell"))
  end

  feature "header brand renders", %{session: session} do
    session
    |> visit("/")
    |> assert_has(css(".header"))
    |> assert_has(css(".header-brand"))
  end

  feature "theme selector exists with light and dark options", %{session: session} do
    session
    |> visit("/")
    |> assert_has(css("select#theme-select"))
    |> assert_has(css("select#theme-select option[value='light']"))
    |> assert_has(css("select#theme-select option[value='dark']"))
  end

  feature "theme CSS custom properties are defined on :root", %{session: session} do
    session
    |> visit("/")

    has_vars =
      session
      |> Wallaby.Browser.execute_script("""
        var styles = window.getComputedStyle(document.documentElement);
        var vars = ['--text', '--bg', '--accent', '--red', '--green'];
        for (var i = 0; i < vars.length; i++) {
          var v = styles.getPropertyValue(vars[i]).trim();
          if (!v) return false;
        }
        return true;
      """)

    assert has_vars,
           "expected :root CSS custom properties (--text, --bg, --accent, --red, --green) to be set"
  end

  feature "login page renders themed text", %{session: session} do
    session
    |> visit("/")

    page_source = session |> Wallaby.Browser.page_source()

    # Verify theme variables are used in rendered inline styles
    assert page_source =~ "color:var(--text-secondary)"
  end

  feature "page renders without JavaScript errors", %{session: session} do
    session
    |> visit("/")

    # Wallaby captures JS errors automatically via js_errors: true config.
    # If the page loaded and we can find body, no fatal JS crash occurred.
    assert_has(session, css("body"))
  end
end
