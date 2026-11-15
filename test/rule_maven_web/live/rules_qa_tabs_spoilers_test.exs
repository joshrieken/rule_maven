defmodule RuleMavenWeb.RulesQaTabsSpoilersTest do
  @moduledoc """
  The Rules Q&A page (formerly "Community Q&A"): the old Unverified tab is split
  into 📖 Prepared (Claude-imported, rulebook-checked rows) and 🧪 Player-asked
  (real players' questions), and answers citing a spoiler source are hidden by
  default / masked until revealed.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.Document

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp log(game, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{game_id: game.id, pooled: true, browsable: true, promoted: false},
          attrs
        )
      )

    q
  end

  setup %{conn: conn} do
    {:ok, viewer} =
      RuleMaven.Users.create_user(%{
        username: "rqa_viewer",
        email: "rqa_viewer@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "Rules QA Game"})

    spoil_doc =
      Repo.insert!(%Document{
        game_id: game.id,
        label: "Spoiler FAQ",
        kind: "faq",
        status: "published",
        spoiler: true
      })

    prepared =
      log(game, %{
        llm_provider: "manual",
        question: "Prepared question about trading?",
        answer: "Trade prepared."
      })

    player =
      log(game, %{
        llm_provider: "openrouter",
        question: "Player question about robbers?",
        answer: "Robber player."
      })

    spoiler =
      log(game, %{
        llm_provider: "manual",
        question: "Secret question about the Diviner class?",
        answer: "Diviner unlocks at scenario nineteen.",
        citations: [%{"quote" => "x", "page" => 1, "document_id" => spoil_doc.id}]
      })

    %{conn: login(conn, viewer), game: game, prepared: prepared, player: player, spoiler: spoiler}
  end

  test "page is titled Rules Q&A, not Community Q&A", %{conn: conn, game: game} do
    {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")
    assert html =~ "Rules Q&amp;A"
    refute html =~ "Community Q&amp;A"
  end

  test "manual rows land in Prepared (default), player rows in Player-asked",
       %{conn: conn, game: game} do
    {:ok, view, html} = live(conn, ~p"/games/#{game}/community")

    # Prepared is the first non-empty tab here.
    assert html =~ "Prepared question about trading?"
    refute html =~ "Player question about robbers?"
    assert html =~ "checked word-for-word"

    html = render_click(view, "switch_tab", %{"tab" => "unverified"})
    assert html =~ "Player question about robbers?"
    refute html =~ "Prepared question about trading?"
    assert html =~ "real players asked"

    html = render_click(view, "switch_tab", %{"tab" => "prepared"})
    assert html =~ "Prepared question about trading?"
  end

  test "tab buttons read Admin-verified / Community / Prepared / Player-asked",
       %{conn: conn, game: game} do
    {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")

    labels =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("button[phx-click=switch_tab]")
      |> LazyHTML.attribute("aria-label")

    assert labels == [
             "Admin-verified (0)",
             "Community (0)",
             "Prepared (1)",
             "Player-asked (1)"
           ]
  end

  test "search badges: Rulebook-checked for prepared, Player-asked for player rows",
       %{conn: conn, game: game} do
    {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")
    html = render_change(view, "search", %{"q" => "question about"})
    assert html =~ "📖 Rulebook-checked"
    assert html =~ "🧪 Player-asked"
    refute html =~ "🧪 Unverified"
  end

  describe "spoilers" do
    test "hidden by default with a count note; no spoiler text anywhere",
         %{conn: conn, game: game} do
      {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")
      assert html =~ "Hide spoilers"
      assert html =~ "1 spoiler answer hidden"
      refute html =~ "Diviner"
    end

    test "search never surfaces a hidden spoiler", %{conn: conn, game: game} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")
      html = render_change(view, "search", %{"q" => "Diviner"})
      refute html =~ "Diviner unlocks"
      refute html =~ "Secret question"
      assert html =~ "0 matches"
    end

    test "turning the toggle off shows a masked card; Reveal shows the text",
         %{conn: conn, game: game, spoiler: spoiler} do
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")
      html = render_click(view, "show_spoilers", %{})

      assert html =~ "⚠️ Spoiler — campaign content"
      refute html =~ "Diviner"
      refute html =~ "spoiler answer hidden"

      # Masked cards do not match searches either.
      html = render_change(view, "search", %{"q" => "Diviner"})
      refute html =~ "Diviner unlocks"
      render_click(view, "clear_search", %{})

      html = render_click(view, "reveal_spoiler", %{"id" => to_string(spoiler.id)})
      assert html =~ "Secret question about the Diviner class?"
      assert html =~ "⚠️ Spoiler"

      # Re-enabling the toggle hides it again.
      html = render_click(view, "toggle_hide_spoilers", %{})
      refute html =~ "Diviner"
    end

    test "tab counts reflect what is listed", %{conn: conn, game: game} do
      {:ok, view, html} = live(conn, ~p"/games/#{game}/community")
      assert html =~ ~s|aria-label="Prepared (1)"|

      html = render_click(view, "show_spoilers", %{})
      assert html =~ ~s|aria-label="Prepared (2)"|
    end
  end
end
