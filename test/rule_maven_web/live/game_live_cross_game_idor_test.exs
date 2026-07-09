defmodule RuleMavenWeb.GameLiveCrossGameIdorTest do
  @moduledoc """
  Handlers that take a row id from `phx-value-id` must scope it to the game whose
  page is open. Being an admin of the app is not the same as acting on the game
  you are looking at, and every one of these ids is attacker-controlled.
  """
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.{Document, GameCategory}
  alias RuleMaven.Repo

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin do
    n = System.unique_integer([:positive])

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "adm#{n}",
        email: "adm#{n}@test.com",
        password: "password1234"
      })

    {:ok, user} = RuleMaven.Users.update_user_role(user, "admin")
    user
  end

  defp doc(game, status) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        label: "Rulebook",
        full_text: "Some rulebook text long enough to estimate.",
        game_id: game.id,
        status: status,
        page_count: 1,
        pages: [%{index: 0, text: "Page one text.", lane: "clean"}]
      })
      |> Repo.insert()

    doc
  end

  defp token(game), do: RuleMaven.Hashid.encode(game.id)

  describe "review page" do
    test "approve_doc cannot touch another game's document", %{conn: conn} do
      mine = published_game_fixture(%{name: "Mine #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      theirs = published_game_fixture(%{name: "Theirs #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      victim = doc(theirs, "pending_review")

      {:ok, view, _} = conn |> login(admin()) |> live(~p"/games/#{token(mine)}/review")
      render_click(view, "approve_doc", %{"id" => to_string(victim.id)})

      assert Repo.get(Document, victim.id).status == "pending_review"
    end

    test "reject_doc cannot touch another game's document", %{conn: conn} do
      mine = published_game_fixture(%{name: "Mine2 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      theirs = published_game_fixture(%{name: "Theirs2 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      victim = doc(theirs, "pending_review")

      {:ok, view, _} = conn |> login(admin()) |> live(~p"/games/#{token(mine)}/review")
      render_click(view, "reject_doc", %{"id" => to_string(victim.id)})

      assert Repo.get(Document, victim.id).status == "pending_review"
    end
  end

  describe "prepare page" do
    test "delete_category cannot permanently delete another game's category", %{conn: conn} do
      mine = published_game_fixture(%{name: "Mine3 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      theirs = published_game_fixture(%{name: "Theirs3 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})

      {:ok, victim} =
        %GameCategory{} |> GameCategory.changeset(%{name: "Setup", game_id: theirs.id}) |> Repo.insert()

      {:ok, view, _} = conn |> login(admin()) |> live(~p"/games/#{token(mine)}/prepare")
      render_click(view, "delete_category", %{"id" => to_string(victim.id)})

      assert Repo.get(GameCategory, victim.id), "another game's category must survive"
    end

    test "delete_category still deletes this game's own category", %{conn: conn} do
      mine = published_game_fixture(%{name: "Mine4 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})

      {:ok, own} =
        %GameCategory{} |> GameCategory.changeset(%{name: "Combat", game_id: mine.id}) |> Repo.insert()

      {:ok, view, _} = conn |> login(admin()) |> live(~p"/games/#{token(mine)}/prepare")
      render_click(view, "delete_category", %{"id" => to_string(own.id)})

      refute Repo.get(GameCategory, own.id), "the admin's own category should still delete"
    end
  end

  describe "scoped lookups" do
    test "get_game_document/2 and get_game_category/2 refuse a foreign id" do
      mine = published_game_fixture(%{name: "Mine5 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      theirs = published_game_fixture(%{name: "Theirs5 #{System.unique_integer([:positive])}", bgg_id: System.unique_integer([:positive])})
      foreign = doc(theirs, "published")

      refute Games.get_game_document(mine, foreign.id)
      assert Games.get_game_document(theirs, foreign.id)

      # A garbage id is nil, not a raise.
      refute Games.get_game_document(mine, "not-an-id")
      refute Games.get_game_category(mine, "99999999")
    end
  end
end
