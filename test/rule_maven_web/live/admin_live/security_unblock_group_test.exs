defmodule RuleMavenWeb.AdminLive.SecurityUnblockGroupTest do
  @moduledoc """
  An admin unblock re-queues the ask. The re-queued job must not launder a group
  row into a public one: AskWorker derives `browsable`/`never_pool`/the publish
  check from the group, and if the re-queue drops the group the row is written
  `browsable: true` (only PublishCheckWorker may do that) and never screened.

  Two layers, both asserted here:
    * security.ex passes the ROW's group_id in the args (belt), and
    * AskWorker reads the row's own group_id anyway (braces) — see
      test/rule_maven/workers/ask_worker_publish_gate_test.exs.
  """
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Workers.AskWorker

  # The app leaves Oban out of its supervision tree in test
  # (RuleMaven.Application.maybe_add_oban/1), so `Oban.insert` in the LiveView
  # raises unless a named instance is running. :manual inserts the job without
  # executing it — exactly what assert_enqueued reads.
  # (:disabled rather than :manual — :manual asserts the Oban migration version,
  # which the app's schema predates; same setup as the AskWorker publish-gate
  # test. Jobs still land in oban_jobs, which is all assert_enqueued reads.)
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user!(prefix, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_#{n}",
            email: "#{prefix}_#{n}@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    u
  end

  test "unblocking a group question re-queues it WITH its group, leaving it unbrowsable", %{
    conn: conn
  } do
    game = published_game_fixture(%{name: "Unblock Game"})
    member = user!("unblock_member")
    admin = user!("unblock_admin", %{role: "admin"})
    {:ok, admin} = RuleMaven.Users.set_super_admin(admin, true)
    grp = group_fixture(member)

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: member.id,
        group_id: grp.id,
        question: "SECRETWORDING is Dave cheating?",
        cleaned_question: "Is a player cheating?",
        answer: "Blocked.",
        promoted: false,
        blocked: true,
        browsable: false
      })

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, _html} = live(conn, ~p"/admin/security")

    render_click(view, "unblock", %{"id" => to_string(q.id)})

    assert_enqueued(
      worker: AskWorker,
      args: %{"question_log_id" => q.id, "group_id" => grp.id}
    )

    # The unblock itself must not publish the row — only PublishCheckWorker may.
    assert Repo.reload!(q).browsable == false
  end
end
