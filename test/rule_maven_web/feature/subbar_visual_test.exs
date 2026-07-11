defmodule RuleMavenWeb.Feature.SubBarVisual do
  @moduledoc """
  Shared fixtures and DOM-geometry probes for the sub-bar visual contract
  (see the moduledocs on the Mobile/Desktop test modules below).

  This is real DOM geometry (`getBoundingClientRect`, `getComputedStyle`),
  which a LiveView `render` test cannot see: rendered HTML/CSS classes look
  identical whether the bar is flush-left or inset by stray padding. Only a
  browser actually laying out the page can catch that.

  Playwright honors the exact requested viewport (no headless-Chrome 500px
  clamp), so the mobile pass really runs at 390px.
  """

  import ExUnit.Assertions
  import PhoenixTest
  import PhoenixTest.Playwright, only: [evaluate: 4]

  alias RuleMaven.{Games, Repo}

  def login(conn, user) do
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)
    visit(conn, "/auto-login?token=#{token}")
  end

  def setup_game(username) do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "password1234",
        role: "admin"
      })

    game = RuleMaven.GamesFixtures.published_game_fixture()

    {:ok, _doc} =
      %Games.Document{}
      |> Games.Document.changeset(%{
        label: "Rulebook",
        full_text: "Test rulebook text.",
        game_id: game.id,
        status: "published",
        html_path: "/priv/html/rulebook.html"
      })
      |> Repo.insert()

    # Enough logged questions that the Community page's list overflows the
    # 390x844 viewport - otherwise `.main-content` never scrolls and the
    # sticky-pin assertion has nothing to exercise.
    for i <- 1..20 do
      {:ok, _q} =
        Games.log_question(%{
          game_id: game.id,
          question: "How does rule #{i} work?",
          answer: "Like this, for reason number #{i}, at length so the row has some height.",
          visibility: "community"
        })
    end

    {admin, game}
  end

  def paths(game) do
    t = RuleMaven.Hashid.encode(game.id)

    [
      {"show", "/games/#{t}"},
      {"community", "/games/#{t}/community"},
      {"prepare", "/games/#{t}/prepare"},
      {"review", "/games/#{t}/review"},
      {"edit", "/games/#{t}/edit"}
    ]
  end

  # Geometry of the bar, read from the live DOM. evaluate/4's callback hands
  # us the JS value; relay it to the test process so asserts can run outside
  # the pipe.
  def probe(conn, script) do
    parent = self()
    evaluate(conn, script, [is_function: true], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, v} -> v
    after
      5_000 -> flunk("probe timed out")
    end
  end

  def geometry_probe do
    """
    () => {
      var bar = document.querySelector('.game-bar');
      if (!bar) return {missing: true};
      var r = bar.getBoundingClientRect();
      var cs = window.getComputedStyle(bar);
      var mc = document.querySelector('.main-content');
      var pill = bar.querySelector('.btn-primary');
      var pillVisible = pill ? window.getComputedStyle(pill).display !== 'none' : false;
      return {
        missing: false,
        left: r.left,
        width: r.width,
        innerWidth: window.innerWidth,
        mcClientWidth: mc.clientWidth,
        bg: cs.backgroundColor,
        position: cs.position,
        zIndex: cs.zIndex,
        pillVisible: pillVisible,
        docScrollWidth: document.documentElement.scrollWidth
      };
    }
    """
  end

  def after_scroll_probe do
    """
    () => {
      var sc = document.querySelector('.main-content');
      sc.scrollTop = 400;
      var bar = document.querySelector('.game-bar');
      var scRect = sc.getBoundingClientRect();
      var barRect = bar.getBoundingClientRect();
      return {
        gap: barRect.top - scRect.top,
        scrolled: sc.scrollTop,
        scrollHeight: sc.scrollHeight,
        clientHeight: sc.clientHeight
      };
    }
    """
  end

  def assert_full_bleed(g, name, label) do
    refute g["missing"], "#{name}: no .game-bar rendered"

    # .main-content scrolls vertically, so its own scrollbar (when content
    # overflows) eats a few px from its clientWidth versus window.innerWidth
    # - full-bleed within a scrolling container means flush against its
    # scrollport (clientWidth), not the raw window, so that's the baseline.
    assert_in_delta g["width"],
                    g["mcClientWidth"],
                    1.0,
                    "#{name} #{label}: bar is not full-bleed (#{g["width"]} vs scrollport #{g["mcClientWidth"]})"

    assert_in_delta g["left"],
                    0.0,
                    1.0,
                    "#{name} #{label}: bar not flush left (left=#{g["left"]})"
  end
end

defmodule RuleMavenWeb.Feature.SubBarVisualMobileTest do
  use PhoenixTest.Playwright.Case,
    async: false,
    browser_context_opts: [viewport: %{width: 390, height: 844}]

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  Guards the `.game-bar` full-bleed contract on every game screen (Show,
  Community, Prepare, Review, Edit) at the 390px mobile viewport: the bar
  spans the scrollport edge-to-edge and sits flush left, its background is
  opaque (the blurred game art must not show through), its desktop pills are
  hidden, the page never grows a horizontal scrollbar, and - since it's
  `position: sticky` - it pins flush to `.main-content`'s top edge after
  scrolling, with no blank band above it.
  """

  import RuleMavenWeb.Feature.SubBarVisual

  test "the bar is full-bleed, opaque and pinned on every game page @390", %{conn: conn} do
    {admin, game} = setup_game("visual_admin_mobile")
    conn = login(conn, admin)

    for {name, path} <- paths(game) do
      g = conn |> visit(path) |> probe(geometry_probe())

      assert_full_bleed(g, name, "@390")

      refute String.contains?(g["bg"], "rgba"),
             "#{name}: bar background is translucent (#{g["bg"]}) - game art will scroll through"

      refute g["pillVisible"], "#{name} @390: pills must be hidden (hide-mobile)"

      assert g["docScrollWidth"] <= g["innerWidth"] + 1,
             "#{name} @390: horizontal overflow (#{g["docScrollWidth"]} > #{g["innerWidth"]})"
    end

    # Sticky: the bar pins to .main-content's top edge, no blank band.
    # Show is excluded on purpose, not just skipped: its bar lives inside
    # `.chat-layout`, which is `position: fixed` and therefore never IS the
    # scroll container - `.main-content` doesn't scroll on Show at all, so
    # sticky positioning is inert there by design, and there is nothing for
    # this probe to exercise on that page.
    for {name, path} <- paths(game), name != "show" do
      s = conn |> visit(path) |> probe(after_scroll_probe())

      assert s["scrollHeight"] > s["clientHeight"],
             "#{name}: fixture content does not overflow .main-content " <>
               "(scrollHeight #{s["scrollHeight"]} <= clientHeight #{s["clientHeight"]}) " <>
               "so the sticky-pin assertion below would silently no-op"

      assert s["scrolled"] > 0,
             "#{name}: .main-content did not actually scroll (scrollTop #{s["scrolled"]})"

      assert_in_delta s["gap"],
                      0.0,
                      2.0,
                      "#{name}: bar did not pin flush (gap #{s["gap"]}px after scroll)"
    end
  end
end

defmodule RuleMavenWeb.Feature.SubBarVisualDesktopTest do
  use PhoenixTest.Playwright.Case,
    async: false,
    browser_context_opts: [viewport: %{width: 1280, height: 900}]

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  Desktop (1280px) counterpart to the mobile sub-bar test: pills reappear
  and the bar stays full-bleed.
  """

  import RuleMavenWeb.Feature.SubBarVisual

  test "pills reappear and the bar stays full-bleed @1280", %{conn: conn} do
    {admin, game} = setup_game("visual_admin_desktop")
    conn = login(conn, admin)

    for {name, path} <- paths(game) do
      g = conn |> visit(path) |> probe(geometry_probe())

      assert g["pillVisible"], "#{name} @1280: pills should be visible"
      assert_full_bleed(g, name, "@1280")
    end
  end
end
