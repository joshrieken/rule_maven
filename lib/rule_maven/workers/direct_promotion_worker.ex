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

  # Per-run candidate cap. Loading every eligible row's embedding is unbounded
  # as the pool grows; the cron re-runs every 15 minutes, so rows past the cap
  # are simply picked up on a later pass (the ordering below is deterministic,
  # and promoted rows drop out of the candidate set).
  @max_rows_per_run 2000

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
        # A row staled by a rulebook change may cite text that has since moved;
        # never promote it into the shared pool until it is re-grounded.
        where: q.stale == false,
        where: not is_nil(q.question_embedding),
        # Deterministic seeding for the greedy clustering below: highest-trust
        # rows seed clusters first, ties broken by id. The same ordering also
        # makes the @max_rows_per_run cut deterministic — the most promotable
        # rows are always in the window.
        order_by: [desc: q.trust_score, asc: q.id],
        limit: @max_rows_per_run,
        select: %{
          id: q.id,
          game_id: q.game_id,
          user_id: q.user_id,
          embedding: q.question_embedding,
          trust_score: q.trust_score,
          has_canonical: not is_nil(q.canonical_answer),
          # Effective question text — used to keep facet-incompatible rows out of
          # the same cluster (see cluster_by_similarity/1).
          text: fragment("coalesce(?, ?)", q.canonical_question, q.question),
          inserted_at: q.inserted_at
        }
    )
    # Convert each pgvector to a plain list ONCE up front — the pairwise
    # clustering below compares embeddings many times, and re-running
    # Pgvector.to_list/1 per comparison dominated the run.
    |> Enum.map(fn row -> %{row | embedding: Pgvector.to_list(row.embedding)} end)
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
  # existing cluster it is close enough to, else seeds a new one. Embeddings are
  # already plain lists (converted once in perform/1). Clusters live in a map
  # keyed by seed order so both "seed a new cluster" and "join cluster i" are
  # O(1) — the old `clusters ++ [[row]]` append re-copied the whole list per
  # new cluster.
  defp cluster_by_similarity(rows) do
    threshold = distance_threshold()

    {clusters, count} =
      Enum.reduce(rows, {%{}, 0}, fn row, {clusters, count} ->
        vec = row.embedding

        idx =
          Enum.find(0..(count - 1)//1, fn i ->
            Enum.any?(clusters[i], fn m ->
              # Near embeddings alone don't merge: a one-token flip (before/after,
              # may/must) barely moves the vector, so also require the questions
              # be facet-compatible. Otherwise a flipped row inherits the
              # cluster's trust and one representative promotes for both verdicts.
              cosine_distance(vec, m.embedding) <= threshold and
                RuleMaven.LLM.QuestionFacets.compatible?(row.text, m.text)
            end)
          end)

        case idx do
          nil -> {Map.put(clusters, count, [row]), count + 1}
          i -> {Map.update!(clusters, i, &[row | &1]), count}
        end
      end)

    Enum.map(0..(count - 1)//1, &clusters[&1])
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
    # The `browsable` filter is re-asserted HERE, not just in the candidate read.
    # `retract_contributions/1` (delete_group/2, sole-owner account deletion) can commit
    # between the two, and a bare update would then land the row in
    # `visibility: "community"` with `browsable: false` — a state every other gate
    # exists to prevent, and one the community browse surfaces (which list on
    # visibility alone) would happily publish.
    {promoted, _} =
      Repo.update_all(
        from(q in QuestionLog,
          where: q.id == ^best.id,
          where: q.browsable == true,
          where: q.visibility != "community"
        ),
        set: [visibility: "community", pooled: true]
      )

    # The rewards must hang off what the UPDATE actually did, not off the earlier
    # SELECT. Settlement is ONE-SHOT and irreversible: it stamps every up-vote
    # `settled_at` (making them permanently immutable) and pays each voter a
    # curator point. Firing it on a promotion the guard above correctly blocked
    # would pay out — and freeze the votes — for a row that was retracted out from
    # under us and is not in the community at all.
    if promoted == 1, do: finalize_promotion(best)

    :ok
  end

  defp finalize_promotion(best) do
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
