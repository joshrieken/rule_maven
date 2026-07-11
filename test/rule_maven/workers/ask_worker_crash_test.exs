defmodule RuleMaven.Workers.AskWorkerCrashTest do
  @moduledoc """
  A RAISE inside AskWorker (as opposed to an `{:error, reason}` return) bypasses
  every terminal write, which used to strand the question on "Thinking..." with no
  error_kind — no retry button, and a concurrency slot burned forever. The rescue
  in `perform/1` guarantees a terminal state on the LAST attempt.

  Both regressions this pins were found in round 12, inside round 11's own rescue:
  the run was closed under the wrong scope (so it stayed "running"), and a
  last-attempt crash AFTER the answer was written clobbered a good answer.
  """
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Jobs, Repo}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Jobs.JobRun
  alias RuleMaven.Workers.AskWorker

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  # A raise deterministically fires inside `do_perform` when the args name a game
  # that does not exist: `Games.get_game!/1` is `Repo.get!`.
  defp crash_job(qlog_id, attempt) do
    %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: attempt,
      max_attempts: 2,
      args: %{
        "game_id" => -1,
        "question_log_id" => qlog_id,
        "question" => "How many dice?",
        "user_id" => nil
      }
    }
  end

  test "a last-attempt crash finalizes the stuck row and closes its run" do
    {:ok, game} = Games.create_game(%{name: "CrashGame"})
    u = user("crash_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice?",
        answer: "Thinking...",
        visibility: "private"
      })

    run =
      Jobs.start_run("ask", {"question", ql.id}, "Ask — crash", oban_job_id: 999)

    # The worker reraises after finalizing, so the crash surfaces (Oban records it
    # and discards) — but the row and the run are left terminal.
    assert_raise Ecto.NoResultsError, fn ->
      AskWorker.perform(crash_job(ql.id, 2))
    end

    row = Repo.get(QuestionLog, ql.id)
    assert String.starts_with?(row.answer, "⚠️"), "stuck row was not finalized"
    assert row.error_kind == "unknown"

    # The scope must match the ask run's own scope ("question"); the round-11 bug
    # closed "question_log" (PublishCheckWorker's scope), matching zero rows.
    assert Repo.get(JobRun, run.id).state == "failed",
           "the crashed ask's run was left running"
  end

  test "a crew-origin row whose crew was deleted still gets a generic job label" do
    # The label is written to job_runs and shown in the admin Jobs panel — outside
    # the crew. A crew row keeps its raw, unscreened wording after the crew is
    # deleted (group_id nilified), so keying the label on a live group_id put the
    # asker's real player names on a shared surface for exactly those rows.
    {:ok, game} = Games.create_game(%{name: "LabelGame"})
    u = user("label_u")

    raw = "Dave says my rogue can sneak past; my brother Sam says no"

    # Crew-origin but nilified: no group_id, unbrowsable. `crew_origin?/1` is true.
    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: raw,
        answer: "Thinking...",
        visibility: "private",
        group_id: nil,
        browsable: false
      })

    # No LLM mock: LLM.ask errors, but `start_run` (and thus the label) runs first.
    AskWorker.perform(%Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: 1,
      max_attempts: 2,
      args: %{
        "game_id" => game.id,
        "question_log_id" => ql.id,
        "question" => raw,
        "user_id" => u.id
      }
    })

    run = Repo.get_by(JobRun, kind: "ask", scope_type: "question", scope_id: ql.id)

    assert run.label == "Ask (crew)"
    refute run.label =~ "Dave"
    refute run.label =~ "Sam"
  end

  test "an EARLY (non-last) attempt crash does not finalize — it lets Oban retry" do
    {:ok, game} = Games.create_game(%{name: "CrashRetryGame"})
    u = user("crash_retry_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice?",
        answer: "Thinking...",
        visibility: "private"
      })

    assert_raise Ecto.NoResultsError, fn ->
      AskWorker.perform(crash_job(ql.id, 1))
    end

    row = Repo.get(QuestionLog, ql.id)
    assert row.answer == "Thinking...", "an early crash should leave the row for a retry"
    assert is_nil(row.error_kind)
  end

  test "a last-attempt crash AFTER a good answer does not clobber the answer" do
    {:ok, game} = Games.create_game(%{name: "CrashGoodGame"})
    u = user("crash_good_u")

    # The row already carries a real answer (error_kind nil) — the shape a crash
    # in broadcast_complete / finish_run / a post-answer enqueue leaves behind.
    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice?",
        answer: "You roll two dice.",
        visibility: "private"
      })

    assert_raise Ecto.NoResultsError, fn ->
      AskWorker.perform(crash_job(ql.id, 2))
    end

    row = Repo.get(QuestionLog, ql.id)

    assert row.answer == "You roll two dice.",
           "a last-attempt crash overwrote a good answer with an error"

    assert is_nil(row.error_kind)
  end
end
