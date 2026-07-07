defmodule RuleMaven.Workers.SettleVotesWorker do
  @moduledoc """
  Settles a row's votes after a terminal trust event (promotion/verify →
  `confirmed`, moderation demotion → `rejected`). `event_at` is captured at
  enqueue time so votes cast after the event never settle even if the job
  runs late. Settlement itself is idempotent, so retries are safe.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:question_log_id, :outcome], period: 60]

  alias RuleMaven.Games.{Curation, QuestionLog}
  alias RuleMaven.Jobs
  alias RuleMaven.Repo

  def enqueue(question_log_id, outcome) when outcome in [:confirmed, :rejected] do
    %{
      question_log_id: question_log_id,
      outcome: to_string(outcome),
      event_at: NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, id: oban_id}) do
    %{"question_log_id" => id, "outcome" => outcome, "event_at" => event_at_iso} = args

    case Repo.get(QuestionLog, id) do
      nil ->
        :ok

      q ->
        {:ok, event_at} = NaiveDateTime.from_iso8601(event_at_iso)

        run =
          Jobs.start_run("settle_votes", {"game", q.game_id}, "Settle votes ##{id}",
            oban_job_id: oban_id
          )

        try do
          {:ok, {correct, incorrect}} =
            Curation.settle_votes(q, String.to_existing_atom(outcome), event_at)

          Jobs.finish_run(run, "ok", "#{outcome}: #{correct} correct, #{incorrect} incorrect")
          :ok
        rescue
          e ->
            Jobs.finish_run(run, "error", Exception.message(e))
            reraise e, __STACKTRACE__
        end
    end
  end
end
