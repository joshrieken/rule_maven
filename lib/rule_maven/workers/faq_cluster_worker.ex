defmodule RuleMaven.Workers.FaqClusterWorker do
  @moduledoc """
  Nightly job: clusters ungrouped question log entries by embedding
  similarity, generates FAQ drafts, auto-publishes high-confidence ones.
  """

  use Oban.Worker, queue: :clustering, max_attempts: 3
  import Ecto.Query
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  @cluster_threshold 0.15

  @impl Oban.Worker
  def perform(_job) do
    # Process each game independently
    game_ids =
      Repo.all(
        from q in QuestionLog,
          where: is_nil(q.cluster_id) and not is_nil(q.question_embedding),
          distinct: true,
          select: q.game_id
      )

    Enum.each(game_ids, &process_game/1)
    :ok
  end

  defp process_game(game_id) do
    # Fetch unclustered questions with embeddings for this game
    questions =
      Repo.all(
        from q in QuestionLog,
          where:
            q.game_id == ^game_id and is_nil(q.cluster_id) and
              not is_nil(q.question_embedding),
          order_by: q.inserted_at
      )

    if length(questions) >= 2 do
      clusters = cluster_questions(questions)

      clusters
      |> Enum.filter(&(length(&1) >= 2))
      |> Enum.each(fn cluster ->
        generate_faq_draft(game_id, cluster)
      end)

      # Mark all processed questions with temporary cluster IDs
      clusters
      |> Enum.with_index(1)
      |> Enum.each(fn {cluster, cluster_idx} ->
        ids = Enum.map(cluster, & &1.id)

        Repo.update_all(
          from(q in QuestionLog, where: q.id in ^ids),
          set: [cluster_id: cluster_idx]
        )
      end)
    end
  end

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
          updated = replace_cluster(rest ++ matched, first_match, question)
          updated

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

  defp generate_faq_draft(game_id, cluster) do
    questions_text =
      cluster
      |> Enum.map(& &1.question)
      |> Enum.uniq()
      |> Enum.join("\n- ")

    answers_text =
      cluster
      |> Enum.map(& &1.answer)
      |> Enum.uniq()
      |> Enum.join("\n---\n")

    prompt = """
    Given these user questions and their answers about a board game, produce a
    single canonical question and a single reconciled answer.

    Questions asked:
    - #{questions_text}

    Existing answers:
    #{answers_text}

    Respond in this exact format:
    QUESTION: <one clear canonical question>
    ANSWER: <reconciled answer, combine all correct info, resolve any disagreements>
    DISAGREEMENT: <"yes" if answers conflict, otherwise "no">
    """

    case RuleMaven.LLM.chat(prompt, "faq_draft",
           system:
             "You distill multiple Q&A exchanges into a single canonical FAQ entry. Be concise and accurate.",
           max_tokens: 512
         ) do
      {:ok, response} ->
        canonical_q =
          parse_field(response, "QUESTION") || cluster |> List.first() |> Map.get(:question)

        canonical_a =
          parse_field(response, "ANSWER") || cluster |> List.first() |> Map.get(:answer)

        RuleMaven.Faq.create_draft_from_cluster(
          game_id,
          cluster,
          String.trim(canonical_q),
          String.trim(canonical_a)
        )

      {:error, _} ->
        # Skip if LLM call fails
        :ok
    end
  end

  defp parse_field(text, field) do
    case Regex.run(~r/#{field}:\s*(.+?)(?:\n[A-Z]+:|\Z)/s, text) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
