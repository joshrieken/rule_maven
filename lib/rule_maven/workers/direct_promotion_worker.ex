defmodule RuleMaven.Workers.DirectPromotionWorker do
  @moduledoc """
  Runs every 15 minutes: promotes well-received questions to the community pool.

  Candidates are pooled (citation-backed), non-refused, not-yet-community rows
  that carry an embedding. They are clustered by embedding similarity (not exact
  string match, so different phrasings of the same question group together). A
  cluster whose best row has crossed `promotion_floor` (the reputation-weighted
  trust threshold) promotes its representative to `visibility = "community"`.
  """

  use Oban.Worker, queue: :clustering, max_attempts: 3
  import Ecto.Query
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  @default_cluster_similarity 0.85

  @impl Oban.Worker
  def perform(_job) do
    Repo.all(
      from q in QuestionLog,
        # A row that may not be listed (browsable == false) must not be
        # promoted either: promotion sets visibility = "community", which
        # makes the row listable everywhere. Group rows start unbrowsable and
        # are flipped only by PublishCheckWorker's own publish check.
        where:
          q.pooled == true and q.browsable == true and q.refused == false and
            q.visibility != "community",
        where: not is_nil(q.question_embedding),
        # Deterministic seeding for the greedy clustering below: highest-trust
        # rows seed clusters first, ties broken by id.
        order_by: [desc: q.trust_score, asc: q.id],
        select: %{
          id: q.id,
          game_id: q.game_id,
          user_id: q.user_id,
          embedding: q.question_embedding,
          trust_score: q.trust_score,
          has_canonical: not is_nil(q.canonical_answer),
          inserted_at: q.inserted_at
        }
    )
    |> Enum.group_by(& &1.game_id)
    |> Enum.each(fn {_game_id, rows} -> promote_clusters(rows) end)

    :ok
  end

  defp promote_clusters(rows) do
    floor = RuleMaven.Games.Trust.promotion_floor()
    quorum = RuleMaven.Games.Trust.promotion_quorum()

    rows
    |> cluster_by_similarity()
    |> Enum.each(fn cluster ->
      max_trust = cluster |> Enum.map(&(&1.trust_score || 0.0)) |> Enum.max()
      best = representative(cluster)

      # Promote only when the trust floor is crossed AND the representative has a
      # quorum of distinct, eligible, non-author voters — so a single (or single
      # high-rep / sybil) vote can't auto-promote.
      if max_trust >= floor and
           RuleMaven.Games.Trust.eligible_voter_count(best.id, best.user_id) >= quorum do
        promote(best)
      end
    end)
  end

  # Greedy single-link clustering on cosine similarity. Each row joins the first
  # existing cluster it is close enough to, else seeds a new one.
  defp cluster_by_similarity(rows) do
    threshold = distance_threshold()

    Enum.reduce(rows, [], fn row, clusters ->
      vec = Pgvector.to_list(row.embedding)

      idx =
        Enum.find_index(clusters, fn cluster ->
          Enum.any?(cluster, fn m ->
            cosine_distance(vec, Pgvector.to_list(m.embedding)) <= threshold
          end)
        end)

      case idx do
        nil -> clusters ++ [[row]]
        i -> List.update_at(clusters, i, &[row | &1])
      end
    end)
  end

  # Prefer an admin-curated row, then highest trust, then most recent.
  defp representative(cluster) do
    cluster
    |> Enum.sort_by(
      fn r -> {r.has_canonical, r.trust_score || 0.0, r.inserted_at} end,
      :desc
    )
    |> List.first()
  end

  defp promote(best) do
    Repo.update_all(
      from(q in QuestionLog, where: q.id == ^best.id),
      set: [visibility: "community", pooled: true]
    )

    # Re-embed the promoted canonical (skip in test — Oban not running).
    unless Application.get_env(:rule_maven, Oban)[:testing] == :manual do
      RuleMaven.Workers.EmbedQuestionWorker.enqueue(best.id)
    end

    # Promotion rewards the author's reputation.
    if best.user_id, do: RuleMaven.Games.Trust.recompute_reputation(best.user_id)

    RuleMaven.Workers.SettleVotesWorker.enqueue(best.id, :confirmed)
  end

  defp cosine_distance(a, b) do
    dot = Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    nb = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    if na == 0.0 or nb == 0.0, do: 1.0, else: 1.0 - dot / (na * nb)
  end

  defp distance_threshold do
    sim =
      case RuleMaven.Settings.get("cluster_similarity_threshold") do
        nil ->
          @default_cluster_similarity

        "" ->
          @default_cluster_similarity

        v ->
          case Float.parse(v),
            do: (
              {f, _} -> f
              :error -> @default_cluster_similarity
            )
      end

    1.0 - sim
  end
end
