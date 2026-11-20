defmodule RuleMavenWeb.GameLive.CoverageUiTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games.Document
  alias RuleMaven.Repo

  # GameLive tests authenticate by seeding the plug session directly
  # (no log_in_user/2 helper in this project — see qa_no_shift_test.exs).
  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp make_user do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "cui_user_#{System.unique_integer([:positive])}",
        email: "cui_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  defp published_doc(game, page_count) do
    {:ok, doc} =
      %Document{game_id: game.id}
      |> Document.changeset(%{
        label: "Rulebook",
        status: "published",
        page_count: page_count
      })
      |> Repo.insert()

    doc
  end

  # Non-admins only reach the Q&A layout (with the sidebar) for playable games;
  # otherwise the "still preparing" screen renders and the panel has no home.
  defp make_playable(game) do
    {:ok, game} =
      game
      |> Ecto.Changeset.change(
        playable: true,
        playable_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update()

    game
  end

  test "sidebar renders coverage percent and a gap nudge", %{conn: conn} do
    game = game_fixture() |> make_playable()
    doc = published_doc(game, 2)
    user = make_user()

    # community grounded page 1 (1 of 2 = 50%); page 2 is a gap
    Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 1})

    Repo.insert!(%RuleMaven.Games.Chunk{
      document_id: doc.id,
      page_number: 2,
      chunk_index: 0,
      content: "Trading\nPlayers may trade resources.",
      section_label: "Trading"
    })

    {:ok, _view, html} = conn |> login(user) |> live(~p"/games/#{game}")

    assert html =~ "Rulebook coverage"
    assert html =~ "50%"
    assert html =~ "Trading"
  end

  test "sub-bar shows the personal title once earned", %{conn: conn} do
    game = game_fixture(%{name: "Catan"}) |> make_playable()
    doc = published_doc(game, 4)
    user = make_user()

    # 1 of 4 personal pages = 25% -> Student
    Repo.insert!(%RuleMaven.Coverage.UserPageCoverage{
      user_id: user.id,
      document_id: doc.id,
      page: 1
    })

    {:ok, _view, html} = conn |> login(user) |> live(~p"/games/#{game}")

    assert html =~ "Catan Student"
  end
end
