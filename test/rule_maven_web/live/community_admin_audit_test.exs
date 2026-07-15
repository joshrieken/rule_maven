defmodule RuleMavenWeb.CommunityAdminAuditTest do
  @moduledoc """
  Admin audit trail on the Community Q&A page. Guards the regression where a
  stateful component per card collided on id when one question rendered in two
  category sections at once.
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{GameCategory, QuestionCategoryTag}

  test "admin loads community page with a question tagged in two categories, and opens the audit",
       %{conn: conn} do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "cadt_admin",
        email: "cadt_admin@test.com",
        password: "password1234",
        role: "admin"
      })

    game = published_game_fixture(%{name: "Cat Repro"})

    cat_a = Repo.insert!(%GameCategory{game_id: game.id, name: "Setup"})
    cat_b = Repo.insert!(%GameCategory{game_id: game.id, name: "Scoring"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: admin.id,
        question: "How do I score?",
        answer: "Count your points.",
        promoted: true,
        verified: true
      })

    ql |> Ecto.Changeset.change(citation_valid: true) |> Repo.update!()

    Repo.insert!(%QuestionCategoryTag{question_log_id: ql.id, game_category_id: cat_a.id})
    Repo.insert!(%QuestionCategoryTag{question_log_id: ql.id, game_category_id: cat_b.id})

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})

    {:ok, view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}/community")

    assert html =~ "Audit trail"

    html = render_click(view, "open_audit", %{"id" => to_string(ql.id)})
    assert html =~ "Question audit trail"
    assert html =~ "How do I score?"
  end
end
