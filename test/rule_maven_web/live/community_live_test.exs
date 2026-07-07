defmodule RuleMavenWeb.CommunityLiveTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  defp log(game, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{game_id: game.id, question: "How does X work?", answer: "Like Y."},
          attrs
        )
      )

    q
  end

  defp setup_game(_) do
    game = published_game_fixture(%{name: "Community Browse Game"})
    asker = create_user("cql_asker")
    viewer = create_user("cql_viewer")

    verified =
      log(game, %{
        visibility: "community",
        verified: true,
        question: "Verified question about scoring?",
        answer: "Score verified."
      })

    community =
      log(game, %{
        visibility: "community",
        question: "Community question about setup?",
        answer: "Setup community."
      })

    unverified =
      log(game, %{
        user_id: asker.id,
        pooled: true,
        visibility: "private",
        question: "Unverified question about movement?",
        answer: "Move unverified."
      })

    %{
      game: game,
      asker: asker,
      viewer: viewer,
      verified: verified,
      community: community,
      unverified: unverified
    }
  end

  describe "Community Q&A page" do
    setup [:setup_game]

    test "renames FAQ: page renders as Community Q&A on both routes",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)

      {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")
      assert html =~ "Community Q&amp;A"

      # Legacy /faq URL still serves the page.
      {:ok, _view, html} = live(conn, ~p"/games/#{game}/faq")
      assert html =~ "Community Q&amp;A"
    end

    test "tabs are disjoint: verified default (first non-empty), others behind their tabs",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)
      {:ok, view, html} = live(conn, ~p"/games/#{game}/community")

      # Default tab: first non-empty left to right — verified here.
      assert html =~ "Verified question about scoring?"
      refute html =~ "Community question about setup?"
      refute html =~ "Unverified question about movement?"

      html = render_click(view, "switch_tab", %{"tab" => "community"})
      assert html =~ "Community question about setup?"
      refute html =~ "Verified question about scoring?"

      html = render_click(view, "switch_tab", %{"tab" => "unverified"})
      assert html =~ "Unverified question about movement?"
      assert html =~ "not yet reviewed"
      refute html =~ "Verified question about scoring?"
    end

    test "default tab skips empty tabs left to right",
         %{conn: conn, viewer: viewer, asker: asker} do
      # Game with only an unverified pooled question — opens on that tab.
      game = published_game_fixture(%{name: "Pool Only Game", bgg_id: 4242})

      log(game, %{
        user_id: asker.id,
        pooled: true,
        visibility: "private",
        question: "Only pooled question here?",
        answer: "Pooled answer."
      })

      conn = login(conn, viewer)
      {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")

      assert html =~ "Only pooled question here?"
      assert html =~ "not yet reviewed"
    end

    test "explicit tab choice patches the URL and survives refresh",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      render_click(view, "switch_tab", %{"tab" => "unverified"})
      assert_patch(view, ~p"/games/#{game}/community?tab=unverified")

      # Reopening the patched URL lands on the chosen tab, not the default.
      {:ok, _view, html} = live(conn, ~p"/games/#{game}/community?tab=unverified")
      assert html =~ "Unverified question about movement?"
      refute html =~ "Verified question about scoring?"
    end

    test "unverified tab hides rows that duplicate a community question",
         %{conn: conn, game: game, viewer: viewer, asker: asker} do
      log(game, %{
        user_id: asker.id,
        pooled: true,
        visibility: "private",
        question: "Community question about setup?",
        answer: "Duplicate of promoted copy."
      })

      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      html = render_click(view, "switch_tab", %{"tab" => "unverified"})
      refute html =~ "Duplicate of promoted copy"
    end

    test "search runs across all tabs at once with status badges",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      html = render_change(view, "search", %{"q" => "question about"})

      # All three surface regardless of the selected tab…
      assert html =~ "Verified question about scoring?"
      assert html =~ "Community question about setup?"
      assert html =~ "Unverified question about movement?"
      # …and carry their status badges.
      assert html =~ "Admin-verified"
      assert html =~ "🌐 Community"
      assert html =~ "🧪 Unverified"

      # Answer text matches too.
      html = render_change(view, "search", %{"q" => "move unverified"})
      assert html =~ "Unverified question about movement?"
      refute html =~ "Community question about setup?"
    end

    test "upvoting an unverified answer records the vote and adds it to the voter's list",
         %{conn: conn, game: game, viewer: viewer, unverified: unverified} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      render_click(view, "switch_tab", %{"tab" => "unverified"})
      html = render_click(view, "vote", %{"id" => to_string(unverified.id)})

      # Tally reflects the new vote.
      assert html =~ "Total helpful votes"
      assert Games.get_user_community_vote(unverified.id, viewer.id)

      ids = game |> Games.recent_questions(20, user_id: viewer.id) |> Enum.map(& &1.id)
      assert unverified.id in ids
    end

    test "reporting works from the browse page",
         %{conn: conn, game: game, viewer: viewer, unverified: unverified} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      render_click(view, "switch_tab", %{"tab" => "unverified"})
      render_click(view, "report_answer", %{"id" => to_string(unverified.id)})
      html = render_click(view, "submit_report", %{"reason" => "wrong"})

      assert html =~ "Reported"
    end

    test "clicking a card's preview expands the full answer with rulebook citations",
         %{conn: conn, game: game, viewer: viewer} do
      cited =
        log(game, %{
          visibility: "community",
          verified: true,
          question: "Cited question about placement?",
          answer: "In reverse order.",
          citations: [
            %{
              "quote" => "Settlements are placed in reverse order.",
              "page" => 12,
              "source" => "Rulebook"
            }
          ]
        })

      conn = login(conn, viewer)
      {:ok, view, html} = live(conn, ~p"/games/#{game}/community")

      refute html =~ "Show less"
      refute html =~ "Settlements are placed in reverse order."

      html = render_click(view, "toggle_expand", %{"id" => to_string(cited.id)})
      assert html =~ "md-answer"
      assert html =~ "Settlements are placed in reverse order."
      assert html =~ "p.12"
      assert html =~ "Show less"

      html = render_click(view, "toggle_expand", %{"id" => to_string(cited.id)})
      refute html =~ "Show less"
      refute html =~ "Settlements are placed in reverse order."
    end

    test "forged ids from other games can't be voted or reported here",
         %{conn: conn, game: game, viewer: viewer} do
      other_game = published_game_fixture(%{name: "Other Game", bgg_id: 43})

      foreign =
        log(other_game, %{pooled: true, visibility: "private", question: "Foreign question?"})

      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      render_click(view, "vote", %{"id" => to_string(foreign.id)})
      refute Games.get_user_community_vote(foreign.id, viewer.id)

      render_click(view, "report_answer", %{"id" => to_string(foreign.id)})
      html = render_click(view, "submit_report", %{"reason" => "wrong"})
      refute html =~ "Reported and pulled"
    end
  end
end
