defmodule RuleMavenWeb.CommunityLiveTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  alias RuleMaven.Games
  alias RuleMaven.Repo
  alias RuleMaven.Games.{GameCategory, QuestionCategoryTag}

  defp category(game, name) do
    Repo.insert!(%GameCategory{game_id: game.id, name: name, description: "#{name} rules."})
  end

  defp tag(question, cat) do
    Repo.insert!(%QuestionCategoryTag{question_log_id: question.id, game_category_id: cat.id})
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
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
        browsable: true,
        question: "Verified question about scoring?",
        answer: "Score verified."
      })

    community =
      log(game, %{
        visibility: "community",
        browsable: true,
        question: "Community question about setup?",
        answer: "Setup community."
      })

    unverified =
      log(game, %{
        user_id: asker.id,
        pooled: true,
        browsable: true,
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
        browsable: true,
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

    test "category pills filter to the selected category; only categories with shown questions get a pill",
         %{conn: conn, game: game, viewer: viewer, unverified: unverified} do
      # unverified question = "Unverified question about movement?"
      movement = category(game, "Movement")
      # Combat exists as a category but tags nothing shown → no pill.
      _combat = category(game, "Combat")
      tag(unverified, movement)

      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")
      html = render_click(view, "switch_tab", %{"tab" => "unverified"})

      # A pill renders for the category that actually has a shown question…
      assert html =~ "Movement"
      # …but not for a category with zero shown questions.
      refute html =~ "Combat"

      # Selecting the category narrows to its questions.
      html = render_click(view, "filter_category", %{"id" => to_string(movement.id)})
      assert html =~ "Unverified question about movement?"

      # Clearing (re-click) restores the full list.
      html = render_click(view, "filter_category", %{"id" => to_string(movement.id)})
      assert html =~ "Unverified question about movement?"
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

  describe "unverified tab never renders a group row's raw question text" do
    setup [:setup_game]

    test "group-origin row shows the scrubbed cleaned_question, never the asker's raw prose",
         %{conn: conn} do
      game = published_game_fixture(%{name: "Group Publish Game", bgg_id: 4343})
      owner = create_user("gpg_owner")
      viewer = create_user("gpg_viewer")
      group = group_fixture(owner)

      {:ok, group_q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: owner.id,
          group_id: group.id,
          pooled: true,
          browsable: true,
          visibility: "private",
          question: "wait can Dave really do that lol",
          cleaned_question: "May a player retract a committed move?",
          # A crew row can only BE browsable if the publish gate cleared it, and the
          # gate refuses any row whose normalize step didn't actually run — so a
          # realistic browsable crew row always records the scrub.
          question_normalized: true,
          answer: "No, a committed move cannot be retracted."
        })

      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      html = render_click(view, "switch_tab", %{"tab" => "unverified"})

      assert html =~ "May a player retract a committed move?"
      refute html =~ "Dave"

      assert group_q.group_id == group.id
    end

    test "group-origin row with no scrubbed text at all withholds rather than leaking raw prose",
         %{conn: conn} do
      game = published_game_fixture(%{name: "Group Withhold Game", bgg_id: 4344})
      owner = create_user("gwg_owner")
      viewer = create_user("gwg_viewer")
      group = group_fixture(owner)

      {:ok, _group_q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: owner.id,
          group_id: group.id,
          pooled: true,
          browsable: true,
          visibility: "private",
          question: "wait can Steve really do that lol",
          answer: "No, that move is not legal."
        })

      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      html = render_click(view, "switch_tab", %{"tab" => "unverified"})

      assert html =~ "(question withheld)"
      refute html =~ "Steve"
    end

    test "non-group row is unchanged: still renders via QuestionLog.display_question/1",
         %{conn: conn, game: game, viewer: viewer, unverified: unverified} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      html = render_click(view, "switch_tab", %{"tab" => "unverified"})

      assert html =~ RuleMaven.Games.QuestionLog.display_question(unverified)
    end
  end

  describe "tool sub-bar" do
    setup [:setup_game]

    test "community page shows the sub-bar and opens tools",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)
      {:ok, view, html} = live(conn, ~p"/games/#{game}/community")

      assert html =~ "tool-subbar"
      refute html =~ "Admin Review →"

      html = render_click(view, "open_tool", %{"tool" => "timer"})
      assert html =~ ~s(id="tool-panel-timer")
    end

    test "sub-bar overview link navigates (cross-LiveView), not patches",
         %{conn: conn, game: game, viewer: viewer} do
      conn = login(conn, viewer)
      {:ok, view, _html} = live(conn, ~p"/games/#{game}/community")

      # The sub-bar puts the emoji in its own `aria-hidden` span, so "🔍 Overview"
      # is no longer one contiguous string in the markup — scope to the More
      # menu's Overview link instead (`element/2` raises unless it matches
      # exactly one, so this still proves the link is there). Patching to
      # another LiveView would crash: it must render as a navigate
      # (data-phx-link="redirect"), never a patch.
      overview =
        view
        |> element(~s|.card-menu__pop a[href="#{~p"/games/#{game}?start=1"}"]|)
        |> render()

      assert overview =~ "Overview"
      assert overview =~ ~s(data-phx-link="redirect")
      refute overview =~ ~s(data-phx-link="patch")
    end
  end
end
