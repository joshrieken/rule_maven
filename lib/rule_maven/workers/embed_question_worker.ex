defmodule RuleMaven.Workers.EmbedQuestionWorker do
  @moduledoc """
  Re-embeds a QuestionLog's canonical_question (falling back to the normalized
  cleaned_question, then the raw question) and stores the vector in
  question_embedding.
  Enqueued whenever admin sets canonical_question on a QuestionLog.

  `unique` keeps at most one active job per question log, so repeated canonical
  edits while a job is queued produce one re-embed, not one per edit.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:question_log_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"question_log_id" => id}}) do
    case Repo.get(QuestionLog, id) do
      nil ->
        # Row deleted while the job was queued — nothing to embed.
        :ok

      q ->
        text = q.canonical_question || q.cleaned_question || q.question

        case RuleMaven.Embed.embed(text) do
          {:ok, vector} ->
            Repo.update_all(
              from(ql in QuestionLog, where: ql.id == ^q.id),
              set: [question_embedding: Pgvector.new(vector)]
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def enqueue(question_log_id) do
    %{"question_log_id" => question_log_id}
    |> new()
    |> Oban.insert()
  end
end
