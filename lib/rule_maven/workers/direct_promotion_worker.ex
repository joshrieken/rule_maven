defmodule RuleMaven.Workers.DirectPromotionWorker do
  @moduledoc """
  Nightly job: finds questions with 3+ upvotes that aren't linked
  to any FAQ entry, and promotes them directly to published FAQ entries.
  Bypasses the clustering step entirely for clear winners.
  """

  use Oban.Worker, queue: :clustering, max_attempts: 3
  import Ecto.Query
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  @min_upvotes 3
  @similarity_threshold 0.08

  @impl Oban.Worker
  def perform(_job) do
    # Find questions with >= 3 upvotes, not yet in any FAQ
    upvoted =
      Repo.all(
        from q in QuestionLog,
          where: q.feedback == "up",
          group_by: [q.game_id, q.question],
          having: count(q.id) >= @min_upvotes,
          select: %{game_id: q.game_id, question: q.question, count: count(q.id)}
      )

    Enum.each(upvoted, fn group ->
      promote_if_new(group)
    end)

    :ok
  end

  defp promote_if_new(%{game_id: game_id, question: question, count: _count}) do
    # Get all upvoted Q&As for this question
    qas =
      Repo.all(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.question == ^question and q.feedback == "up"
      )

    if qas != [] do
      # Embed the question
      question_embedding =
        case RuleMaven.Embed.embed(question) do
          {:ok, vec} -> vec
          {:error, _} -> nil
        end

      # Check similarity against existing FAQ entries
      is_new =
        if question_embedding do
          threshold = @similarity_threshold

          match =
            Repo.one(
              from f in RuleMaven.Faq.FaqEntry,
                where:
                  f.game_id == ^game_id and f.status == "published" and
                    not is_nil(f.question_embedding),
                where:
                  fragment(
                    "cosine_distance(?, ?::vector)",
                    f.question_embedding,
                    ^Pgvector.new(question_embedding)
                  ) <= ^threshold,
                limit: 1
            )

          is_nil(match)
        else
          true
        end

      if is_new do
        source_ids = Enum.map(qas, & &1.id)
        best_answer = qas |> List.first() |> Map.get(:answer)

        RuleMaven.Faq.create_faq(%{
          game_id: game_id,
          canonical_question: question,
          canonical_answer: best_answer,
          question_embedding: question_embedding,
          source_qa_ids: source_ids,
          status: "published",
          auto_approved: true,
          auto_approve_reason: "#{length(qas)} upvotes, direct promotion"
        })
      end
    end
  end
end
