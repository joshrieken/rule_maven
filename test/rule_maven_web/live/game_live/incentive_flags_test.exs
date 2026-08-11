defmodule RuleMavenWeb.GameLive.IncentiveFlagsTest do
  @moduledoc """
  The admin kill switches over the two incentive features: `:mastery_levels`
  (XP bar, levels, persona unlocks) and `:rulebook_coverage` (coverage meter,
  gap nudges, personal title). Off means the UI vanishes; the underlying data
  keeps being recorded so nothing is lost while the feature is dark.
  """

  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Repo

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp make_user do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "iflag_user_#{System.unique_integer([:positive])}",
        email: "iflag_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

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

  defp published_doc(game, page_count) do
    {:ok, doc} =
      %RuleMaven.Games.Document{game_id: game.id}
      |> RuleMaven.Games.Document.changeset(%{
        label: "Rulebook",
        status: "published",
        page_count: page_count
      })
      |> Repo.insert()

    doc
  end

  describe ":mastery_levels" do
    test "off hides the XP bar", %{conn: conn} do
      user = make_user()
      game = published_game_fixture(%{name: "Flagged HUD Game"})

      {:ok, _} = RuleMaven.Flags.disable(:mastery_levels)

      {:ok, _view, html} =
        conn |> login(user) |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

      refute html =~ "mastery-hud"
      refute html =~ "Lv 0"
    end
  end

  describe ":rulebook_coverage" do
    setup %{conn: conn} do
      game = game_fixture() |> make_playable()
      doc = published_doc(game, 2)
      user = make_user()

      Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 1})

      Repo.insert!(%RuleMaven.Games.Chunk{
        document_id: doc.id,
        page_number: 2,
        chunk_index: 0,
        content: "Trading\nPlayers may trade resources.",
        section_label: "Trading"
      })

      %{conn: login(conn, user), game: game, user: user, doc: doc}
    end

    test "on, the meter and the gap nudge render", %{conn: conn, game: game} do
      {:ok, _view, html} = live(conn, ~p"/games/#{game}")

      assert html =~ "Rulebook coverage"
      assert html =~ "50%"
    end

    test "off, the meter and the gap nudge vanish", %{conn: conn, game: game} do
      {:ok, _} = RuleMaven.Flags.disable(:rulebook_coverage)

      {:ok, _view, html} = live(conn, ~p"/games/#{game}")

      refute html =~ "Rulebook coverage"
      refute html =~ "coverage-panel"
    end

    test "off, coverage is still recorded, so turning it on shows it at once", ctx do
      %{conn: conn, game: game, doc: doc} = ctx
      {:ok, _} = RuleMaven.Flags.disable(:rulebook_coverage)

      {:ok, _view, _html} = live(conn, ~p"/games/#{game}")

      # A page grounded while the feature was dark still counts.
      Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 2})

      {:ok, _} = RuleMaven.Flags.enable(:rulebook_coverage)
      {:ok, _view, html} = live(conn, ~p"/games/#{game}")

      assert html =~ "Rulebook coverage"
      assert html =~ "100%"
    end
  end
end
