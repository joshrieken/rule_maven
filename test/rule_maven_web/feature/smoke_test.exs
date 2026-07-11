defmodule RuleMavenWeb.Feature.SmokeTest do
  use RuleMavenWeb.FeatureCase, async: false

  @moduledoc """
  Browser-only smoke tests: things a real rendering engine must verify.
  Plain HTML-presence smoke tests live in test/rule_maven_web/smoke_flow_test.exs
  (ConnCase — milliseconds, no Chrome).
  """

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

  feature "page renders without JavaScript errors", %{session: session} do
    session
    |> visit("/")

    # Wallaby captures JS errors automatically via js_errors: true config.
    # If the page loaded and we can find body, no fatal JS crash occurred.
    assert_has(session, css("body"))
  end
end
