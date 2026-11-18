defmodule RuleMavenWeb.GameLiveQueryBudgetTest do
  @moduledoc """
  The game page's connected mount runs in the LiveView socket process, so every
  query it makes delays the join (and the heartbeat). Keep the count flat: it
  must not grow with the number of rulebooks, expansions or covered pages.
  (Measured on real data with test/perf/page_queries_test.exs.)
  """

  # async: false — the telemetry handler is global; no other test may run
  # queries while this one counts.
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Games.{Chunk, Document}
  alias RuleMaven.Repo
  alias RuleMaven.Settings.Cache

  # fun_with_flags reads are ETS-cached outside the test build.
  @uncounted ["fun_with_flags_toggles"]
  @budget 28

  setup do
    # Settings are ETS-cached in production (off in the suite for sandbox
    # isolation); this test is async: false, so turn the cache on for it.
    Application.put_env(:rule_maven, :cache_settings, true)
    Cache.flush()

    on_exit(fn ->
      Application.put_env(:rule_maven, :cache_settings, false)
      Cache.flush()
    end)
  end

  defp doc!(game, label, pages) do
    doc =
      Repo.insert!(%Document{
        game_id: game.id,
        label: label,
        status: "published",
        page_count: pages
      })

    for page <- 1..pages, idx <- 0..1 do
      Repo.insert!(%Chunk{
        document_id: doc.id,
        page_number: page,
        chunk_index: idx,
        content: "#{label} page #{page}\nRules text.",
        section_label: "Section #{page}"
      })
    end

    doc
  end

  defp count_queries(fun) do
    parent = self()
    handler = "budget-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:rule_maven, :repo, :query],
      fn _, _, meta, _ ->
        if meta.source not in @uncounted, do: send(parent, {:query, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:query, sql} -> drain([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "connected mount stays within the query budget with several rulebooks and expansions",
       %{conn: conn} do
    %{game: game, user: user} = qa_thread_fixture(question_count: 6)

    docs = [doc!(game, "Rulebook II", 12), doc!(game, "Scenario book", 20)]

    expansion_docs =
      for n <- 1..3 do
        exp = game_fixture(%{name: "Expansion #{n}", bgg_id: 1000 + n})
        RuleMaven.Games.link_expansion(exp.id, game.id)
        doc!(exp, "Expansion #{n} rules", 6)
      end

    for doc <- docs ++ expansion_docs, page <- [1, 2] do
      Repo.insert!(%PageCoverage{
        document_id: doc.id,
        page: page,
        first_covered_by_user_id: user.id
      })
    end

    conn =
      conn
      |> Plug.Test.init_test_session(%{"user_id" => user.id})
      |> get(~p"/games/#{game}")

    queries =
      count_queries(fn ->
        {:ok, view, html} = live(conn)
        assert html =~ "Rulebook coverage"
        GenServer.stop(view.pid)
      end)

    assert length(queries) <= @budget,
           "game page connected mount ran #{length(queries)} queries (budget #{@budget}):\n" <>
             Enum.map_join(queries, "\n", &String.slice(&1, 0, 140))
  end

  test "Prepare's connected mount loads documents once and doesn't grow per document",
       %{conn: conn} do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "budget_admin_#{System.unique_integer([:positive])}",
        email: "budget_admin_#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "admin"
      })

    game = game_fixture(%{name: "Budget Prep", bgg_id: 2001, bgg_data: "<items/>"})
    for n <- 1..4, do: doc!(game, "Book #{n}", 3)

    conn =
      conn
      |> Plug.Test.init_test_session(%{"user_id" => admin.id})
      |> get(~p"/games/#{game}/prepare")

    queries =
      count_queries(fn ->
        {:ok, view, _html} = live(conn)
        GenServer.stop(view.pid)
      end)

    full_document_loads = Enum.count(queries, &(&1 =~ ~s(d0."full_text")))
    assert full_document_loads == 1

    assert length(queries) <= 40,
           "prepare connected mount ran #{length(queries)} queries:\n" <>
             Enum.map_join(queries, "\n", &String.slice(&1, 0, 140))
  end
end
