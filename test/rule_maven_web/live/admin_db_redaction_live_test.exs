defmodule RuleMavenWeb.AdminDbRedactionLiveTest do
  @moduledoc """
  The `/admin/db` sensitive-column masking must hold on EVERY render of the list,
  not just the initial load. A plain admin deleting a row (an ordinary use of this
  tool) re-fetches the table — and that sink re-rendered raw crew prose because it
  skipped `redact_sensitive`. Every `@rows` sink now routes through `load_rows/3`;
  this drives the LiveView to prove it.
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias RuleMaven.{Games, Repo}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin(name) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  defp raw_question_rows do
    {:ok, game} = Games.create_game(%{name: "RedactGame"})
    u = admin("redact_asker")

    for i <- 1..3 do
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          user_id: u.id,
          question: "Dave's rogue sneaks past Sarah #{i}?",
          answer: "No.",
          visibility: "private"
        })
    end
  end

  test "a plain admin never sees raw question text — not on load, not after a delete" do
    raw_question_rows()
    conn = login(build_conn(), admin("redact_viewer"))

    {:ok, view, _html} = live(conn, ~p"/admin/db?table=questions_log")

    # Load path.
    html = render(view)
    refute html =~ "Dave", "load path leaked raw question text"
    assert html =~ "«redacted»"

    # Delete path: delete one row, which re-fetches and re-renders the table.
    id = Repo.one!(from q in RuleMaven.Games.QuestionLog, order_by: [desc: q.id], limit: 1).id

    html = render_click(view, "delete_row", %{"id" => to_string(id)})

    refute html =~ "Dave", "delete re-render leaked raw question text"
    assert html =~ "«redacted»"
  end
end
