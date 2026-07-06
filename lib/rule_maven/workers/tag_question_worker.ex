defmodule RuleMaven.Workers.TagQuestionWorker do
  use Oban.Worker, queue: :default, max_attempts: 3
  alias RuleMaven.Games

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"question_log_id" => id, "game_id" => game_id}}) do
    # Tag this job's llm_logs rows with the question they serve (admin LLM
    # trace) — see RuleMaven.LLM.current_question_log_id/0.
    Logger.metadata(question_log_id: id)

    Games.tag_question(id, game_id)
    :ok
  end

  def enqueue(question_log_id, game_id) do
    if Application.get_env(:rule_maven, Oban)[:testing] == :manual do
      :ok
    else
      %{"question_log_id" => question_log_id, "game_id" => game_id}
      |> new()
      |> Oban.insert()
    end
  end
end
