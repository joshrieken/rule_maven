defmodule RuleMavenWeb.AdminLive.QuestionsTest do
  @moduledoc """
  Admins/super admins must always see real question/answer content in the
  admin Questions list (the `browsable`/group withholding gate is meant to
  keep crew content away from *other users*, not from admins auditing it),
  and must be able to filter the list down to a single asker.
  """

  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.{Games, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_super_admin(username) do
    {:ok, user} =
      Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.set_super_admin(user, true)
    admin
  end

  defp create_user(username) do
    {:ok, user} =
      Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: "password1234"
      })

    user
  end

  defp game, do: elem(Games.create_game(%{name: "Game #{System.unique_integer([:positive])}"}), 1)

  test "super admin sees the raw question/answer for a withheld (crew, unscrubbed) row", %{
    conn: conn
  } do
    admin = create_super_admin("qsuper")
    asker = create_user("qasker")
    g = game()

    {:ok, q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: asker.id,
        question: "the asker's verbatim raw question",
        answer: "the raw answer text",
        browsable: false,
        group_id: nil,
        question_normalized: false
      })

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/questions")

    html = render_click(view, "expand", %{"id" => to_string(q.id)})

    assert html =~ "the asker&#39;s verbatim raw question"
    assert html =~ "the raw answer text"
    refute html =~ "withheld"
  end

  test "expanded answer shows the citation source and page, not just the bare quote", %{
    conn: conn
  } do
    admin = create_super_admin("qsuper3")
    asker = create_user("qasker3")
    g = game()

    {:ok, q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: asker.id,
        question: "can I play it immediately?",
        answer: "with one exception...",
        cited_passage: "That card, however, may not be a card you bought this turn.",
        cited_source: "Catan Rulebook",
        cited_page: 7
      })

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/questions")

    html = render_click(view, "expand", %{"id" => to_string(q.id)})

    assert html =~ "Catan Rulebook"
    assert html =~ "p.7"
    assert html =~ "That card, however"
  end

  test "questions list can be filtered down to a single user", %{conn: conn} do
    admin = create_super_admin("qsuper2")
    target = create_user("qtarget")
    other = create_user("qother")
    g = game()

    {:ok, _target_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: target.id,
        question: "target's question",
        answer: "target's answer"
      })

    {:ok, _other_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: other.id,
        question: "other's question",
        answer: "other's answer"
      })

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/questions")

    html =
      render_click(view, "select_user", %{
        "id" => to_string(target.id),
        "username" => target.username
      })

    assert html =~ "target&#39;s question"
    refute html =~ "other&#39;s question"

    # Deep link via ?user_id=, e.g. from the Manage Users page.
    {:ok, _view2, html2} = conn |> login(admin) |> live(~p"/admin/questions?user_id=#{target.id}")
    assert html2 =~ target.username
    assert html2 =~ "target&#39;s question"
  end
end
