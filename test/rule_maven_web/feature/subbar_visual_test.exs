defmodule RuleMavenWeb.Feature.SubBarVisualTest do
  use RuleMavenWeb.FeatureCase, async: false

  @moduledoc """
  Guards the `.game-bar` full-bleed contract on every game screen (Show,
  Community, Prepare, Review, Edit): the bar spans the scrollport edge-to-edge
  and sits flush left, its background is opaque (the blurred game art must not
  show through), its desktop pills hide at narrow widths, the page never grows
  a horizontal scrollbar, and — since it's `position: sticky` — it pins flush
  to `.main-content`'s top edge after scrolling, with no blank band above it.

  This is real DOM geometry (`getBoundingClientRect`, `getComputedStyle`), which
  a LiveView `render` test cannot see: rendered HTML/CSS classes look identical
  whether the bar is flush-left or inset by stray padding. Only a browser
  actually laying out the page can catch that, so this stays a Wallaby feature
  test rather than being folded into a unit test.

  Caveat: headless Chrome clamps `resize_window` to a 500px minimum width, so
  the "mobile" pass below actually runs at 500px, not the requested 390px.
  `.hide-mobile` elements stay `display: none` below 640px either way, so the
  pill-visibility assertions still exercise the intended behavior — just be
  aware the viewport-width numbers in failures will read ~500, not ~390.
  """

  alias RuleMaven.{Games, Repo}

  defp login(session, user) do
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)
    visit(session, "/auto-login?token=#{token}")
  end

  defp setup_game do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "visual_admin",
        email: "visual_admin@test.com",
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

    {:ok, _q} =
      Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        visibility: "community"
      })

    {admin, game}
  end

  defp token(game), do: RuleMaven.Hashid.encode(game.id)

  # execute_script/2 returns the session; only the /4 arity hands you the value.
  defp probe(session, script) do
    parent = self()
    Wallaby.Browser.execute_script(session, script, [], fn v -> send(parent, {:probe, v}) end)

    receive do
      {:probe, v} -> v
    after
      5_000 -> flunk("probe timed out")
    end
  end

  # Geometry of the bar, read from the live DOM.
  @probe """
  var bar = document.querySelector('.game-bar');
  if (!bar) return {missing: true};
  var r = bar.getBoundingClientRect();
  var cs = window.getComputedStyle(bar);
  var mc = document.querySelector('.main-content');
  var pill = bar.querySelector('.btn-primary, .sources-dropdown');
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
  """

  @after_scroll """
  var sc = document.querySelector('.main-content');
  sc.scrollTop = 400;
  var bar = document.querySelector('.game-bar');
  var scRect = sc.getBoundingClientRect();
  var barRect = bar.getBoundingClientRect();
  return {gap: barRect.top - scRect.top, scrolled: sc.scrollTop};
  """

  feature "the bar is full-bleed, opaque and pinned on every game page", %{session: session} do
    {admin, game} = setup_game()
    t = token(game)

    paths = [
      {"show", "/games/#{t}"},
      {"community", "/games/#{t}/community"},
      {"prepare", "/games/#{t}/prepare"},
      {"review", "/games/#{t}/review"},
      {"edit", "/games/#{t}/edit"}
    ]

    session = login(session, admin)

    # ── Mobile: 390px requested, clamped to 500px (see @moduledoc) ──────────
    session = Wallaby.Browser.resize_window(session, 390, 844)

    for {name, path} <- paths do
      g = session |> visit(path) |> probe(@probe)

      refute g["missing"], "#{name}: no .game-bar rendered"

      # .main-content scrolls vertically, so its own scrollbar (when content
      # overflows) eats a few px from its clientWidth versus window.innerWidth
      # — full-bleed within a scrolling container means flush against its
      # scrollport (clientWidth), not the raw window, so that's the baseline.
      assert_in_delta g["width"], g["mcClientWidth"], 1.0,
                      "#{name} @390: bar is not full-bleed (#{g["width"]} vs scrollport #{g["mcClientWidth"]})"

      assert_in_delta g["left"], 0.0, 1.0, "#{name} @390: bar not flush left"

      refute String.contains?(g["bg"], "rgba"),
             "#{name}: bar background is translucent (#{g["bg"]}) — game art will scroll through"

      refute g["pillVisible"], "#{name} @390: pills must be hidden (hide-mobile)"

      assert g["docScrollWidth"] <= g["innerWidth"] + 1,
             "#{name} @390: horizontal overflow (#{g["docScrollWidth"]} > #{g["innerWidth"]})"
    end

    # ── Sticky: the bar pins to .main-content's top edge, no blank band ─────
    for {name, path} <- paths, name != "show" do
      s = session |> visit(path) |> probe(@after_scroll)

      if s["scrolled"] > 0 do
        assert_in_delta s["gap"], 0.0, 2.0,
                        "#{name}: bar did not pin flush (gap #{s["gap"]}px after scroll)"
      end
    end

    # ── Desktop: pills reappear ────────────────────────────────────────────
    session = Wallaby.Browser.resize_window(session, 1280, 900)

    for {name, path} <- paths do
      g = session |> visit(path) |> probe(@probe)

      assert g["pillVisible"], "#{name} @1280: pills should be visible"
    end
  end
end
