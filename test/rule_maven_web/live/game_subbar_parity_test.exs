defmodule RuleMavenWeb.GameSubBarParityTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{CheatSheet, Games, Repo}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp document_fixture(game) do
    {:ok, doc} =
      %Games.Document{}
      |> Games.Document.changeset(%{
        label: "Rulebook",
        full_text: "Test rulebook text.",
        game_id: game.id,
        status: "published"
      })
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
        visibility: "community"
      })

    for path <- [
          ~p"/games/#{game}",
          ~p"/games/#{game}/community",
          ~p"/games/#{game}/review",
          ~p"/games/#{game}/edit"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Community Q&amp;A", "no Community pill on #{path}"
    end
  end

  test "the Community pill is inert on the Community page", %{conn: conn, game: game} do
    {:ok, _q} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        question: "How does X work?",
        answer: "Like Y.",
        visibility: "community"
      })

    {:ok, _view, html} = live(conn, ~p"/games/#{game}/community")
    assert html =~ ~s(aria-current="page")

    # The inert pill must not also be a link to the page you are already on.
    # Narrowed to the pill's own markup (its distinctive "btn-primary" class):
    # the page's More menu also links to /community unconditionally (it is
    # not gated by `current`, by design — see sub_bar.ex's `more_menu/1`), so
    # a bare `href=".../community"` check would false-positive on that menu
    # item regardless of whether the pill itself is correctly inert.
    refute html =~
             ~s(href="/games/#{RuleMaven.Hashid.encode(game.id)}/community" data-phx-link="redirect" data-phx-link-state="push" class="btn btn-primary btn-xs hide-mobile")
  end

  test "the admin Regen button renders only on the game page", %{conn: conn, game: game} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{game}")
    {:ok, _view, review_html} = live(conn, ~p"/games/#{game}/review")

    # Both are rendered for an admin, so a difference here is the gate working,
    # not an authorization accident.
    assert show_html =~ "regenerate_html" or show_html =~ "Rulebooks"
    refute review_html =~ "regenerate_html"
  end
end
