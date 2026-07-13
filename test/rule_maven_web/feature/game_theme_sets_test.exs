defmodule RuleMavenWeb.Feature.GameThemeSetsTest do
  @moduledoc """
  Browser contract for multi-set game themes: the header picker folds every
  generated set into its "Match game" optgroup (set 1 on the legacy
  `game-light`/`game-dark` slugs, set 2+ on `game-N-…`), selecting one applies
  its `[data-theme=…]` variable block, a standing selection that this game
  doesn't offer falls back to set 1 of the same scheme, and the overview
  "Dress this page" pill grows a "Try another look" cycler when more than one
  set exists. All of that is root-layout + hook JS a LiveView render test
  can't see.
  """
  use PhoenixTest.Playwright.Case,
    async: false,
    browser_context_opts: [viewport: %{width: 1280, height: 900}]

  import PhoenixTest.Playwright, only: [evaluate: 4]

  alias RuleMaven.Games

  @moduletag :feature

  @sets %{
    "sets" => [
      %{
        "light" => %{"--bg" => "#F6EEE8", "--bg-surface" => "#FFFFFF", "--text" => "#302020"},
        "dark" => %{"--bg" => "#201010", "--bg-surface" => "#2A1614", "--text" => "#E8D8CC"}
      },
      %{
        "light" => %{"--bg" => "#EAF4F4", "--bg-surface" => "#FFFFFF", "--text" => "#203030"},
        "dark" => %{"--bg" => "#101E20", "--bg-surface" => "#16282A", "--text" => "#C8DCDC"}
      }
    ]
  }
  @set_names %{
    "sets" => [
      %{"light" => "Harbor Daylight", "dark" => "Longest Night"},
      %{"light" => "Tide Morning", "dark" => "Deep Current"}
    ]
  }

  setup do
    game = RuleMaven.GamesFixtures.published_game_fixture()
    {:ok, game} = Games.update_game(game, %{theme_palette: @sets, theme_names: @set_names})

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "theme_sets_#{suffix}",
        email: "theme_sets_#{suffix}@test.com",
        password: "testpassword123"
      })

    # Mark every tour seen so the spotlight overlay can't sit on top of the
    # pills this test clicks.
    seen = Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})
    {:ok, user} = RuleMaven.Users.update_user(user, %{tours_seen: seen})

    %{game: game, user: user, path: "/games/#{RuleMaven.Hashid.encode(game.id)}"}
  end

  defp login_and_visit(conn, user, path) do
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)

    conn
    |> visit("/auto-login?token=#{token}")
    |> visit(path)
  end

  defp probe(conn, script) do
    parent = self()
    evaluate(conn, script, [is_function: true], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, v} -> v
    after
      15_000 -> flunk("probe timed out")
    end
  end

  test "picker offers every set and applies the chosen set's variables", %{
    conn: conn,
    user: user,
    path: path
  } do
    conn = login_and_visit(conn, user, path)

    options =
      probe(conn, """
      () => {
        var group = document.getElementById('theme-select-game-group');
        if (!group) return {missing: true};
        return {
          missing: false,
          options: Array.prototype.map.call(group.children, function(o) {
            return {value: o.value, label: o.textContent.trim()};
          })
        };
      }
      """)

    refute options["missing"], "game optgroup never folded into #theme-select"

    assert options["options"] == [
             %{"value" => "game-light", "label" => "🖌️ Harbor Daylight"},
             %{"value" => "game-dark", "label" => "🖌️ Longest Night"},
             %{"value" => "game-2-light", "label" => "🖌️ Tide Morning"},
             %{"value" => "game-2-dark", "label" => "🖌️ Deep Current"}
           ]

    applied =
      probe(conn, """
      () => {
        var sel = document.getElementById('theme-select');
        sel.value = 'game-2-dark';
        sel.dispatchEvent(new Event('change', {bubbles: true}));
        return {
          theme: document.documentElement.getAttribute('data-theme'),
          bg: getComputedStyle(document.documentElement).getPropertyValue('--bg').trim(),
          stored: localStorage.getItem('themeGameMatch')
        };
      }
      """)

    assert applied["theme"] == "game-2-dark"
    assert applied["stored"] == "game-2-dark"
    assert String.upcase(applied["bg"]) == "#101E20"
  end

  test "a standing selection this game doesn't offer falls back to set 1, same scheme", %{
    conn: conn,
    user: user,
    path: path
  } do
    conn = login_and_visit(conn, user, path)

    fallen =
      probe(conn, """
      () => {
        localStorage.setItem('themeGameMatch', 'game-4-dark');
        window.dispatchEvent(new Event('phx:page-loading-stop'));
        return {
          theme: document.documentElement.getAttribute('data-theme'),
          picker: document.getElementById('theme-select').value
        };
      }
      """)

    assert fallen["theme"] == "game-dark"
    assert fallen["picker"] == "game-dark"
  end

  test "dress pill applies set 1 and the restyle pill cycles sets in-scheme", %{
    conn: conn,
    user: user,
    path: path
  } do
    conn = login_and_visit(conn, user, path)

    # The pills are driven by a LiveView hook — wait for the socket to join
    # (hooks mounted) before clicking, or the click lands on a dead button.
    # The join takes several seconds in this harness, so poll rather than
    # assert_has with its default timeout.
    connected =
      probe(conn, """
      () => new Promise(function(resolve) {
        var tries = 0;
        (function poll() {
          var main = document.querySelector('[data-phx-main]');
          if (main && main.classList.contains('phx-connected')) return resolve(true);
          if (tries++ > 100) return resolve(false);
          setTimeout(poll, 100);
        })();
      })
      """)

    assert connected, "LiveSocket never connected — hook pills would be dead"

    dressed =
      probe(conn, """
      () => {
        var hint = document.getElementById('game-theme-hint');
        hint.querySelector('[data-role="dress"]').click();
        var restyle = hint.querySelector('[data-role="restyle"]');
        return {
          theme: document.documentElement.getAttribute('data-theme'),
          restyleShown: !restyle.hidden,
          restyleLabel: restyle.textContent.trim()
        };
      }
      """)

    # Default base theme on a fresh context is light → set 1 light.
    assert dressed["theme"] == "game-light"
    assert dressed["restyleShown"]
    assert dressed["restyleLabel"] == "🎲 Try another look (1/2)"

    cycled =
      probe(conn, """
      () => {
        var hint = document.getElementById('game-theme-hint');
        var restyle = hint.querySelector('[data-role="restyle"]');
        restyle.click();
        var after = {
          theme: document.documentElement.getAttribute('data-theme'),
          label: restyle.textContent.trim()
        };
        restyle.click();
        after.wrapped = document.documentElement.getAttribute('data-theme');
        return after;
      }
      """)

    assert cycled["theme"] == "game-2-light"
    assert cycled["label"] == "🎲 Try another look (2/2)"
    assert cycled["wrapped"] == "game-light"
  end
end
