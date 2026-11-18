defmodule RuleMavenWeb.Perf.PageQueriesTest do
  @moduledoc """
  Query counts and timings per page against REAL data — a measuring tool, not a
  regression test (excluded by default; the regression ceilings live next to
  each page's own tests).

  Run it against a copy of the dev database (never production):

      createdb -U postgres rule_maven_test_perfdata
      pg_dump -U postgres rule_maven_dev | psql -q -U postgres rule_maven_test_perfdata
      MIX_TEST_PARTITION=_perfdata mix test --only perf test/perf

  It picks the game with the most questions, the game with the most expansions
  and the busiest super admin, then times each page's dead render and its
  connected mount (including any start_async work) separately: the connected
  mount is what blocks the LiveView socket process.
  """

  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias RuleMaven.Repo

  @moduletag :perf
  @moduletag timeout: :infinity
  @runs 5

  setup do
    # Production caches settings in ETS (off in the suite for sandbox
    # isolation): measure the steady state production sees.
    Application.put_env(:rule_maven, :cache_settings, true)
    RuleMaven.Settings.Cache.flush()

    on_exit(fn ->
      Application.put_env(:rule_maven, :cache_settings, false)
      RuleMaven.Settings.Cache.flush()
    end)

    parent = self()
    ref = make_ref()

    :telemetry.attach(
      "perf-#{inspect(ref)}",
      [:rule_maven, :repo, :query],
      fn _event, measurements, meta, _ ->
        # fun_with_flags reads are ETS-cached in production (its cache is
        # compiled out of the test build), so they don't count here.
        if meta.source != "fun_with_flags_toggles" do
          send(
            parent,
            {:perf_query, ref, measurements[:total_time] || 0, {meta.source, meta.query}}
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("perf-#{inspect(ref)}") end)
    {:ok, ref: ref}
  end

  test "page query counts and timings", %{conn: conn, ref: ref} do
    user =
      Repo.one(
        from u in RuleMaven.Users.User,
          left_join: q in "questions_log",
          on: q.user_id == u.id,
          where: u.role == "super_admin",
          group_by: u.id,
          order_by: [desc: count(q.id)],
          limit: 1
      )

    if is_nil(user), do: flunk("no super admin in this database — load real data first")

    busiest =
      Repo.one(
        from q in "questions_log",
          join: d in "documents",
          on: d.game_id == q.game_id,
          group_by: q.game_id,
          order_by: [desc: count(q.id, :distinct)],
          limit: 1,
          select: q.game_id
      )

    with_expansions =
      Repo.one(
        from l in "game_expansion_links",
          join: d in "documents",
          on: d.game_id == l.base_game_id,
          group_by: l.base_game_id,
          order_by: [desc: count(l.expansion_id, :distinct)],
          limit: 1,
          select: l.base_game_id
      )

    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    tok = &RuleMaven.Hashid.encode/1

    pages = [
      {"home", "/"},
      {"game (busiest)", "/games/#{tok.(busiest)}"},
      {"game (expansions)", "/games/#{tok.(with_expansions)}"},
      {"prepare", "/games/#{tok.(busiest)}/prepare"},
      {"community", "/games/#{tok.(busiest)}/community"},
      {"standing", "/standing"},
      {"groups", "/groups"},
      {"settings", "/settings"},
      {"admin", "/admin"},
      {"admin db", "/admin/db"},
      {"admin security", "/admin/security"},
      {"admin moderation", "/admin/moderation"},
      {"admin usage", "/admin/usage"},
      {"admin themes", "/admin/themes"}
    ]

    rows =
      for {name, path} <- pages do
        # Warm caches once (steady state), then take the median of @runs.
        measure(conn, path, ref)

        samples = for _ <- 1..@runs, do: measure(conn, path, ref)
        {name, path, median(samples)}
      end

    IO.puts(
      "\n| page | dead q | dead ms | connected q | connected ms | conn db ms | top sources |"
    )

    IO.puts("|---|---|---|---|---|---|---|")

    for {name, _path, {dq, dms, cq, cms, cdb, top}} <- rows do
      IO.puts("| #{name} | #{dq} | #{dms} | #{cq} | #{cms} | #{cdb} | #{top} |")
    end
  end

  defp measure(conn, path, ref) do
    flush(ref)
    {dead_us, dead_conn} = :timer.tc(fn -> get(conn, path) end)
    {dq, _, _} = collect(ref)

    {conn_us, _} =
      :timer.tc(fn ->
        {:ok, view, _} = live(dead_conn)
        render_async(view, 10_000)
        GenServer.stop(view.pid)
      end)

    {cq, cdb_native, queries} = collect(ref)

    if System.get_env("PERF_DETAIL") == path do
      for {t, {_src, sql}} <- Enum.reverse(queries) do
        ms = System.convert_time_unit(t, :native, :microsecond) / 1000
        IO.puts("#{Float.round(ms, 2)}ms  #{String.slice(sql, 0, 160)}")
      end

      IO.puts("----")
    end

    # Sources ranked by time spent in them (count in brackets).
    top =
      queries
      |> Enum.group_by(fn {_, {src, _}} -> src || "raw" end, fn {t, _} -> t end)
      |> Enum.map(fn {src, ts} -> {src, length(ts), Enum.sum(ts)} end)
      |> Enum.sort_by(fn {_, _, t} -> -t end)
      |> Enum.take(4)
      |> Enum.map_join(" ", fn {src, n, t} ->
        "#{src}×#{n}(#{System.convert_time_unit(t, :native, :millisecond)}ms)"
      end)

    {dq, div(dead_us, 1000), cq, div(conn_us, 1000),
     System.convert_time_unit(cdb_native, :native, :millisecond), top}
  end

  defp collect(ref, acc \\ {0, 0, []}) do
    receive do
      {:perf_query, ^ref, t, query} ->
        {n, total, queries} = acc
        collect(ref, {n + 1, total + t, [{t, query} | queries]})
    after
      50 -> acc
    end
  end

  defp flush(ref) do
    receive do
      {:perf_query, ^ref, _, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp median(samples) do
    sorted = Enum.sort_by(samples, &elem(&1, 3))
    Enum.at(sorted, div(length(sorted), 2))
  end
end
