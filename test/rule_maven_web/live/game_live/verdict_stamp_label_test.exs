defmodule RuleMavenWeb.GameLive.VerdictStampLabelTest do
  # The legal/illegal stamp reads LEGAL MOVE / NOT ALLOWED only when the
  # question asks about permission. A factual yes/no question ("Do eliminated
  # Survivors contribute to the Danger Level?") answered `illegal` used to wear
  # ❌ NOT ALLOWED; it now reads ❌ NO.
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  import Ecto.Query

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp render_thread(conn, question, verdict) do
    %{game: game, user: user, thread_ids: [id]} = qa_thread_fixture(question_count: 1)

    Repo.update_all(from(q in QuestionLog, where: q.id == ^id),
      set: [question: question, cleaned_question: question, verdict: verdict]
    )

    {:ok, view, _html} =
      conn |> login(user) |> live(~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(id)}")

    view |> element(".verdict-stamp") |> render()
  end

  test "a factual yes/no question gets YES / NO, not a permission stamp", %{conn: conn} do
    html =
      render_thread(conn, "Do eliminated Survivors contribute to the Danger Level?", "illegal")

    assert html =~ ~r/<\/span>\s*NO\s*<\/div>/
    refute html =~ "NOT ALLOWED"
  end

  test "a permission question keeps LEGAL MOVE / NOT ALLOWED", %{conn: conn} do
    html = render_thread(conn, "Can I attack a zombie in my own zone?", "illegal")
    assert html =~ "NOT ALLOWED"
  end

  test "a negatively-phrased question keeps the action label", %{conn: conn} do
    # Its Yes/No is inverted vs the verdict ("No disadvantage" = the attack is
    # fine), so YES/NO would read backwards; LEGAL MOVE describes the action.
    html =
      render_thread(
        conn,
        "Is there a disadvantage to attacking zombies within your own zone?",
        "legal"
      )

    assert html =~ "LEGAL MOVE"
  end
end
