defmodule RuleMaven.Workers.FaqClusterJob do
  @moduledoc """
  Nightly job: groups recent thumbs-down (or frequently asked) questions
  into faq_candidates for admin review.

  Runs per-game. For each game with questions in the last 48h:
  1. Collect questions, group by embedding similarity.
  2. For each cluster >= 2 questions, upsert a faq_candidate.
  3. Candidates sorted by thumbs_down_count desc (most problematic first).
  """

  use Oban.Worker, queue: :clustering, max_attempts: 3
  import Ecto.Query
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  @cluster_threshold 0.15
  @min_cluster_size 2
  @lookback_hours 48

  @impl Oban.Worker
  def perform(_job) do
    since = DateTime.add(DateTime.utc_now(), -@lookback_hours, :hour)

    # Get games with recent questions
    game_ids =
      Repo.all(
        from q in QuestionLog,
          where: q.inserted_at >= ^since,
          distinct: true,
          select: q.game_id
      )

    Enum.each(game_ids, &process_game(&1, since))
    :ok
  end

  defp process_game(game_id, since) do
    questions =
      Repo.all(
        from q in QuestionLog,
          where:
            q.game_id == ^game_id and q.inserted_at >= ^since and
              not is_nil(q.question_embedding) and q.refused == false,
          order_by: q.inserted_at
      )

    if length(questions) >= @min_cluster_size do
      clusters = cluster_questions(questions)

      clusters
      |> Enum.filter(&(length(&1) >= @min_cluster_size))
      |> Enum.each(fn cluster ->
        upsert_candidate_for_cluster(game_id, cluster)
      end)
    end
  end

  defp upsert_candidate_for_cluster(game_id, cluster) do
    # Pick the most representative question (first in cluster)
    representative = List.first(cluster)

    # Count feedback
    thumbs_down =
      Enum.count(cluster, fn q -> q.feedback == "down" end)

    total_asked = length(cluster)

    # Sample answer from the most recent thumbs-down, or the first one
    sample =
      case Enum.find(cluster, &(&1.feedback == "down")) do
        nil -> representative
        q -> q
      end

    RuleMaven.Faq.upsert_candidate(%{
      game_id: game_id,
      question_text: representative.question,
      cluster_id: nil,
      sample_answer_text: sample.answer,
      sample_citation: sample.cited_passage,
      thumbs_down_count: thumbs_down,
      total_asked_count: total_asked,
      status: "pending"
    })
  end

  # ── Clustering (same algorithm as FaqClusterWorker) ──

  defp cluster_questions(questions) do
    questions
    |> Enum.reduce([], fn question, clusters ->
      {matched, rest} =
        Enum.split_with(clusters, fn cluster ->
          centroid = cluster_centroid(cluster)
          dist = cosine_distance(question.question_embedding, centroid)
          dist <= @cluster_threshold
        end)

      case matched do
        [first_match | _] ->
          replace_cluster(rest ++ matched, first_match, question)

        [] ->
          rest ++ [[question]]
      end
    end)
  end

  defp cluster_centroid(cluster) do
    vectors = Enum.map(cluster, & &1.question_embedding)
    count = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, 768), fn vec, acc ->
      Enum.zip(acc, vec) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / count))
  end

  defp replace_cluster(clusters, old_cluster, question) do
    Enum.map(clusters, fn c -> if c == old_cluster, do: c ++ [question], else: c end)
  end

  defp cosine_distance(v1, v2) do
    dot = Enum.zip(v1, v2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    norm1 = :math.sqrt(Enum.map(v1, fn x -> x * x end) |> Enum.sum())
    norm2 = :math.sqrt(Enum.map(v2, fn x -> x * x end) |> Enum.sum())

    if norm1 == 0.0 or norm2 == 0.0 do
      1.0
    else
      1.0 - dot / (norm1 * norm2)
    end
  end
end
