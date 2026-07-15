defmodule RuleMavenWeb.GameSubBarParityTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{CheatSheet, Games, Repo}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp document_fixture(game, attrs \\ %{}) do
    {:ok, doc} =
      %Games.Document{}
      |> Games.Document.changeset(
        Map.merge(
          %{
            label: "Rulebook",
            full_text: "Test rulebook text.",
            game_id: game.id,
            status: "published"
          },
          attrs
        )
      )
      |> Repo.insert()

    doc
  end

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

  setup %{conn: conn} do
    game = published_game_fixture()
    admin = create_user("subbar_admin", %{role: "admin"})
    %{conn: login(conn, admin), game: game, admin: admin}
  end

  test "the game page patches to the overview; other pages navigate", %{conn: conn, game: game} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    # A patch link carries data-phx-link="patch"; a navigate link, "redirect".
    assert show_html =~ ~s(data-phx-link="patch")

    {:ok, _view, community_html} = live(conn, ~p"/games/#{game}/community")
    refute community_html =~ ~s(data-phx-link="patch")
    assert community_html =~ ~s(data-phx-link="redirect")
  end

  test "has_cheatsheet?/1 is true only when some source has an active version", %{game: game} do
    alias RuleMavenWeb.GameLive.ToolHost

    refute ToolHost.has_cheatsheet?([])

    doc_without_version = document_fixture(game)
    refute ToolHost.has_cheatsheet?([doc_without_version])

    doc_with_version = document_fixture(game)
    {:ok, _version} = CheatSheet.save_version(doc_with_version.id, "Cheat sheet content")
    assert ToolHost.has_cheatsheet?([doc_with_version])

    assert ToolHost.has_cheatsheet?([doc_without_version, doc_with_version])
  end

  test "every game page renders the Community pill", %{conn: conn, game: game} do
    # The pill only appears once the game has a community question to point at.
    {:ok, _q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        promoted: true
      })

    for path <- [
          ~p"/games/#{game}",
          ~p"/games/#{game}/community",
          ~p"/games/#{game}/prepare",
          ~p"/games/#{game}/review",
          ~p"/games/#{game}/edit"
        ] do
      {:ok, _view, html} = live(conn, path)

      # `more_menu/1` also renders the text "Community Q&amp;A (...)" on every
      # page under the same @community_count > 0 gate, so a bare text
      # assertion would still pass with `header_pills/1`'s <.pill_link> call
      # deleted outright. Narrow to markup only the pill emits: its
      # `btn btn-primary btn-xs hide-mobile` class list (the More-menu item
      # carries `card-menu__item` instead).
      assert html =~ ~s(class="btn btn-primary btn-xs hide-mobile"),
             "no Community pill on #{path}"
    end
  end

  test "on the Community page the pill becomes My Q&A, pointing back at the game page",
       %{conn: conn, game: game} do
    {:ok, _q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        promoted: true
      })

    # Parse structurally with LazyHTML (the HTML engine LiveViewTest already
    # ships with in this project) rather than matching literal attribute
    # strings: Phoenix.Component.link/1 controls attribute emission order, so
    # a hardcoded `href="..." data-phx-link="redirect" ... class="..."`
    # sequence is a dead assertion waiting to happen the moment a Phoenix
    # upgrade reorders them.
    pill = fn html -> html |> LazyHTML.from_document() |> LazyHTML.query(".btn-primary") end

    {:ok, _view, community_html} = live(conn, ~p"/games/#{game}/community")
    on_community = pill.(community_html)

    assert LazyHTML.text(on_community) =~ "My Q&A",
           "the pill on the Community page must offer the way back to your own Q&A"

    refute LazyHTML.text(on_community) =~ "Community Q&A",
           "the pill must not still advertise the page you are already on"

    assert LazyHTML.attribute(on_community, "href") == [~p"/games/#{game}"],
           "My Q&A must link to the game page, not to Community"

    # ...and the same slot still reads "Community Q&A" everywhere else.
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    on_show = pill.(show_html)

    assert LazyHTML.text(on_show) =~ "Community Q&A",
           "the game page keeps the Community Q&A pill"

    assert LazyHTML.attribute(on_show, "href") == [~p"/games/#{game}/community"]
  end

  test "the admin Regen button renders only on the game page", %{conn: conn, game: game} do
    _doc = document_fixture(game, %{html_path: "/priv/html/rulebook.html"})

    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    {:ok, _view, community_html} = live(conn, ~p"/games/#{game}/community")

    # Both pages must actually render the Rulebooks dropdown for the gate
    # assertions below to be meaningful.
    assert show_html =~ "Rulebooks"
    assert community_html =~ "Rulebooks"

    # `regenerate_html` only has a handler on show.ex; the gate must keep it
    # off every other game page or an admin clicking it there crashes the
    # LiveView.
    assert show_html =~ "regenerate_html"
    refute community_html =~ "regenerate_html"
  end

  test "the desktop Rulebooks dropdown is gone", %{conn: conn, game: game} do
    _doc = document_fixture(game, %{html_path: "/priv/html/rulebook.html"})

    {:ok, _view, html} = live(conn, ~p"/games/#{game}")
    refute html =~ "sources-dropdown"
  end

  test "regenerate_html is absent for non-admins", %{game: game} do
    _doc = document_fixture(game, %{html_path: "/priv/html/rulebook.html"})
    regular = create_user("subbar_regular")

    {:ok, _view, html} = login(build_conn(), regular) |> live(~p"/games/#{game}")
    refute html =~ ~s(phx-click="regenerate_html")
  end

  test "every game page wraps the bar in the same chrome", %{conn: conn, game: game} do
    for path <- [
          ~p"/games/#{game}",
          ~p"/games/#{game}/community",
          ~p"/games/#{game}/prepare",
          ~p"/games/#{game}/review",
          ~p"/games/#{game}/edit"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "game-bar", "no .game-bar chrome on #{path}"
    end
  end
end
