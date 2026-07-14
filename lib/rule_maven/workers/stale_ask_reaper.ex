defmodule RuleMaven.Workers.StaleAskReaper do
  @moduledoc """
  Heals questions stranded on "Thinking..." with no job left to finish them.

  `AskWorker` already finalizes a crashed ask — but only from a `rescue`, which
  runs on a RAISE. A worker process that is KILLED never unwinds through it:
  a node restart mid-ask, an OOM, a linked task exiting abnormally. The job then
  discards (or its row simply outlives it) while the row sits on "Thinking...",
  with `error_kind` still nil. That state is not an error the user can retry —
  it is a permanent spinner. Worse, `pending_count` is recomputed from the DB on
  every mount, so the row permanently consumes one of that user's concurrency
  slots for the game.

  Found in the wild: a real user's Catan question sat on "Thinking..." for six
  days. Nothing in the system would ever have cleared it.

  This is the backstop for every way an ask can die without finalizing itself,
  including the ones not yet imagined. It runs on cron and is safe to repeat.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{Jobs, Repo}
  alias RuleMaven.Workers.AskWorker

  # The grace window before a "Thinking..." row is presumed dead. It must clear
  # the LONGEST a legitimately-live ask can stay pending, or the reaper races a
  # working job and overwrites a real answer with "⚠️":
  #
  #   * @ask_hard_timeout_ms is 180s, and AskWorker has max_attempts: 2  -> 6 min
  #   * Oban's Lifeline returns a job orphaned in `executing` to the queue only
  #     after `rescue_after: 10 min` — until then it is neither running nor dead
  #   * plus queue backlog, which is unbounded in principle
  #
  # 30 minutes sits well clear of 10 + 6, and the cost of waiting is only that a
  # doomed spinner spins a little longer. The cost of being too eager is
  # clobbering a good answer, so the asymmetry decides it. Tunable, but do not
  # drop it below the Lifeline window.
  @default_grace_minutes 30

  # A backstop, not a bulk migration: if this ever finds hundreds of rows, some
  # other thing is broken and the fix belongs there. The cap keeps one bad cron
  # tick from writing "⚠️" across the whole table.
  @default_max_rows 200

  @impl Oban.Worker
  def perform(_job) do
    rows = stranded()

    Enum.each(rows, fn row ->
      AskWorker.finalize_stranded(
        %{"question_log_id" => row.id, "game_id" => row.game_id},
        "stranded on \"Thinking...\" with no live job; reaped after #{grace_minutes()}m"
      )
    end)

    if rows != [] do
      run =
        Jobs.start_run("stale_ask_reaper", {"system", 0}, "Reaped #{length(rows)} stranded ask(s)")

      Jobs.finish_run(run, "done", "Finalized #{length(rows)} question(s) stuck on \"Thinking...\".")
    end

    :ok
  end

  @doc """
  Rows on "Thinking..." past the grace window that no live Oban job will finish.

  The live-job check is the whole safety property. A row whose job is still
  `available`/`scheduled`/`executing`/`retryable` is NOT stranded, however old it
  looks — a long queue backlog is not a crash, and reaping one would overwrite an
  answer that is about to arrive.
  """
  def stranded do
    cutoff = DateTime.add(DateTime.utc_now(), -grace_minutes(), :minute)

    # Jobs that still intend to write a row. Oban's Pruner only deletes jobs in
    # terminal states, so a live job is always still here to be seen.
    # The parens inside the fragment are load-bearing: `?->>'k'::bigint` casts the
    # string literal 'k', not the extracted value, and Postgres rejects it (22P02).
    live_ids =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: not is_nil(fragment("?->>'question_log_id'", j.args)),
        select: fragment("(?->>'question_log_id')::bigint", j.args)
      )

    Repo.all(
      from(q in QuestionLog,
        where: q.answer == "Thinking...",
        where: q.inserted_at < ^cutoff,
        where: q.id not in subquery(live_ids),
        order_by: [asc: q.id],
        limit: ^max_rows(),
        select: %{id: q.id, game_id: q.game_id}
      )
    )
  end

  defp grace_minutes do
    parse_int(RuleMaven.Settings.get("stale_ask_grace_minutes"), @default_grace_minutes)
  end

  defp max_rows do
    parse_int(RuleMaven.Settings.get("stale_ask_max_rows"), @default_max_rows)
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default
end
