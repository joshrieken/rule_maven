defmodule RuleMavenWeb.Feature.LiveNavFlickerTest do
  use PhoenixTest.Playwright.Case,
    async: false,
    browser_context_opts: [viewport: %{width: 390, height: 844}]

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  Pages move live without flicker (PLATFORM.md §6): after a live navigation
  (`<.link navigate>`, the socket stays open) the new page must arrive in one
  piece — no layout shift, no entrance animation replaying, and no DOM churn
  after it has painted (a placeholder swapped for the real content).

  A probe installed once on the first full page load survives every live
  navigation (no reload) and records, per navigation: `layout-shift` entries,
  `animationstart` events, and DOM mutations inside the LiveView container
  that land after `phx:page-loading-stop` plus a short grace period.
  """

  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  alias RuleMaven.Repo

  # Mutations this soon after page-loading-stop still belong to the patch
  # that ended the navigation; later ones are content arriving after paint.
  @grace_ms 150
  @settle_ms 900

  @probe """
  () => {
    if (window.__navProbe) return true;
    const probe = window.__navProbe = {shifts: [], anims: [], muts: [], stop: null};
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (!e.hadRecentInput) {
          probe.shifts.push({value: e.value, at: e.startTime,
            nodes: (e.sources || []).map(s => (s.node && s.node.nodeName + "." + (s.node.className || "")) + " " +
              JSON.stringify([s.previousRect.x, s.previousRect.y, s.previousRect.width, s.previousRect.height]) + "->" +
              JSON.stringify([s.currentRect.x, s.currentRect.y, s.currentRect.width, s.currentRect.height])).join(" | "),
          });
        }
      }
    }).observe({type: "layout-shift", buffered: false});
    const describe = (el) => el && el.nodeType === 1
      ? el.nodeName.toLowerCase() + (el.id ? "#" + el.id : "") +
        (typeof el.className === "string" && el.className ? "." + el.className.trim().split(/\\s+/).join(".") : "")
      : String(el && el.nodeName);
    // An entrance animation counts only if it actually plays (one finished
    // before its first frame shows nothing).
    document.addEventListener("animationstart", (e) => {
      const running = e.target.getAnimations().some(a => a.animationName === e.animationName && a.playState === "running");
      if (running) probe.anims.push({name: e.animationName, el: describe(e.target), at: performance.now()});
    }, true);
    new MutationObserver((records) => {
      const at = performance.now();
      for (const r of records) {
        if (r.type === "attributes" && /^(data-phx|phx-|class$|style$)/.test(r.attributeName) &&
            r.target.closest && r.target.closest(".page-progress")) continue;
        probe.muts.push({at, type: r.type, attr: r.attributeName || null, el: describe(r.target),
          added: r.addedNodes.length, removed: r.removedNodes.length});
      }
    }).observe(document.body, {subtree: true, childList: true, attributes: true, characterData: true});
    window.addEventListener("phx:page-loading-stop", () => { probe.stop = performance.now(); });
    return true;
  }
  """

  setup do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "navflicker_#{System.unique_integer([:positive])}",
        email: "navflicker_#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "admin"
      })

    seen = Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})

    user =
      user |> Ecto.Changeset.change(tours_seen: seen, role: "super_admin") |> Repo.update!()

    %{game: game} = qa_thread_fixture(question_count: 3)
    group = group_fixture(user, %{name: "Flicker Crew"})

    %{user: user, game: game, group: group}
  end

  defp js(conn, script, arg \\ nil) do
    parent = self()
    ref = make_ref()

    body =
      if arg,
        do: "() => (#{script})(#{Jason.encode!(arg)})",
        else: script

    evaluate(conn, body, [is_function: true], fn v -> send(parent, {ref, v}) end)

    receive do
      {^ref, v} -> v
    after
      10_000 -> flunk("probe timed out")
    end
  end

  # Navigate like a <.link navigate>: a phx redirect link clicked in the page.
  defp live_navigate(conn, path) do
    js(
      conn,
      """
      (path) => {
        const p = window.__navProbe;
        p.shifts = []; p.anims = []; p.muts = []; p.stop = null;
        p.started = performance.now();
        const a = document.createElement("a");
        a.href = path;
        a.setAttribute("data-phx-link", "redirect");
        a.setAttribute("data-phx-link-state", "push");
        a.style.display = "none";
        document.querySelector("[data-phx-main]").appendChild(a);
        a.click();
        return true;
      }
      """,
      path
    )

    conn
  end

  defp report(conn) do
    js(
      conn,
      """
      (opts) => new Promise((resolve) => {
        const p = window.__navProbe;
        const wait = () => {
          if (p.stop === null) return setTimeout(wait, 50);
          setTimeout(() => {
            const late = p.muts.filter(m => m.at > p.stop + opts.grace);
            resolve({
              path: location.pathname,
              shift: p.shifts.reduce((s, e) => s + e.value, 0),
              shifts: p.shifts,
              anims: p.anims.filter(a => !/infinite|blob|sweep|float|pulse|typing|spin/.test(a.name)),
              late: late.slice(0, 15),
              stop: p.stop,
              lateCount: late.length,
              navMs: Math.round(p.stop - p.started)
            });
          }, opts.settle);
        };
        wait();
      })
      """,
      %{grace: @grace_ms, settle: @settle_ms}
    )
  end

  test "live navigation across the main pages has no shift, replayed entrance or late swap",
       %{conn: conn, user: user, game: game, group: group} do
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)
    tok = RuleMaven.Hashid.encode(game.id)

    conn =
      conn
      |> visit("/auto-login?token=#{token}")
      |> assert_has(".phx-connected")

    true = js(conn, @probe)

    paths = [
      "/games/#{tok}",
      "/",
      "/games/#{tok}/community",
      "/games/#{tok}",
      "/games/#{tok}/prepare",
      "/standing",
      "/groups",
      "/groups/#{Phoenix.Param.to_param(group)}",
      "/settings",
      "/admin",
      "/admin/db",
      "/admin/usage",
      "/admin/moderation",
      "/admin/security",
      "/admin/themes",
      "/"
    ]

    results =
      for path <- paths do
        conn |> live_navigate(path) |> report()
      end

    problems =
      for r <- results, problem = problems(r), problem != [], do: {r["path"], problem}

    assert problems == [], "live navigation flicker:\n" <> inspect(problems, pretty: true)
  end

  # The persistent `.container` taking the new page's width/padding in the
  # very frame the new page appears is the page change itself, not a shift
  # anyone sees (every page sets its own frame via CSS :has rules).
  defp swap_frame?(shift, r),
    do: String.starts_with?(shift["nodes"], "DIV.container ") and shift["at"] - r["stop"] < 20

  defp problems(r) do
    anims = Enum.reject(r["anims"], &(&1["name"] == "page-progress"))
    shifts = Enum.reject(r["shifts"], &swap_frame?(&1, r))

    Enum.map(anims, &{:entrance_animation, &1["name"], &1["el"]}) ++
      Enum.map(shifts, &{:layout_shift, &1["value"], &1["nodes"]}) ++
      Enum.map(r["late"], &{:late_dom_change, &1})
  end
end
