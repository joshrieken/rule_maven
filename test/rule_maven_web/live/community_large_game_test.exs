defmodule RuleMavenWeb.CommunityLargeGameTest do
  @moduledoc """
  Games with hundreds of answers (Claude-imported pre-fills): the Community Q&A
  page used to load only the newest 200 per tab, so its counts disagreed with
  the sub-bar button and answers past #200 were unsearchable. Now everything
  loads; the grouped view renders a few cards per category with "Show all".
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{GameCategory, QuestionCategoryTag}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  setup do
    {:ok, viewer} =
      RuleMaven.Users.create_user(%{
        username: "clg_viewer",
        email: "clg_viewer@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "Big Community Game"})
    cat = Repo.insert!(%GameCategory{game_id: game.id, name: "Combat", description: "Fights."})

    for i <- 1..205 do
      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          question: "Big question number #{i}?",
          answer: "Answer #{i}.",
          llm_provider: "manual",
          pooled: true,
          browsable: true,
          promoted: false
        })

      if i <= 25,
        do: Repo.insert!(%QuestionCategoryTag{question_log_id: q.id, game_category_id: cat.id})
    end

    %{viewer: viewer, game: game, cat: cat}
  end

  test "tab count covers every answer, not just 200", %{conn: conn, viewer: v, game: game} do
    {:ok, _view, html} = conn |> login(v) |> live(~p"/games/#{game}/community?tab=unverified")

    labels =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("button[phx-value-tab=unverified]")
      |> LazyHTML.attribute("aria-label")

    assert Enum.any?(labels, &(&1 =~ "(205)"))
  end

  test "search reaches answers past the 200th", %{conn: conn, viewer: v, game: game} do
    {:ok, view, _html} = conn |> login(v) |> live(~p"/games/#{game}/community?tab=unverified")
    # every one of the 205 is searchable (with a 200 cap at most 200 could match)
    html = render_change(view, "search", %{"q" => "Big question"})
    assert html =~ "205 matches"
  end

  test "grouped view shows 10 per category with a Show all button that expands it",
       %{conn: conn, viewer: v, game: game, cat: cat} do
    {:ok, view, html} = conn |> login(v) |> live(~p"/games/#{game}/community?tab=unverified")

    cards = fn h ->
      h
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#category-#{cat.id} [data-question-card]")
      |> Enum.count()
    end

    assert cards.(html) == 10
    assert html =~ "Show all 25"

    html = view |> element("#category-#{cat.id} button", "Show all 25") |> render_click()
    assert cards.(html) == 25
    refute html =~ "Show all 25"
  end

  test "search renders at most 100 cards and says so", %{conn: conn, viewer: v, game: game} do
    {:ok, view, _html} = conn |> login(v) |> live(~p"/games/#{game}/community?tab=unverified")
    html = render_change(view, "search", %{"q" => "Big question"})
    assert html =~ "205 matches"
    assert html =~ "showing the first 100"

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-question-card]")
           |> Enum.count() == 100
  end
end
