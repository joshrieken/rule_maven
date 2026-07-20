defmodule RuleMaven.Coverage do
  @moduledoc """
  Rulebook Coverage Engine context: resolves citation source labels to
  published `RuleMaven.Games.Document` ids.
  """

  import Ecto.Query

  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Coverage.UserPageCoverage
  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Games.Document
  alias RuleMaven.Repo

  @doc """
  Builds a downcased published-document label ⇒ document_id map across the
  given games. Only `status == "published"` documents with a non-nil `label`
  are included.
  """
  @spec document_label_map([integer()]) :: %{String.t() => integer()}
  def document_label_map(game_ids) do
    Repo.all(
      from d in Document,
        where: d.game_id in ^game_ids and d.status == "published" and not is_nil(d.label),
        select: {d.label, d.id}
    )
    |> Map.new(fn {label, id} -> {String.downcase(label), id} end)
  end

  @doc """
  Stamps `"document_id"` onto each citation whose `"source"` label resolves
  (case-insensitively) against a published document over the given games.
  Citations that don't resolve are left unchanged (no `"document_id"` key).
  """
  @spec resolve_document_ids([map()], [integer()]) :: [map()]
  def resolve_document_ids(citations, game_ids) do
    label_map = document_label_map(game_ids)

    Enum.map(citations, fn c ->
      case c["source"] && Map.get(label_map, String.downcase(c["source"])) do
        nil -> c
        doc_id -> Map.put(c, "document_id", doc_id)
      end
    end)
  end

  @doc "Record covered (document_id, page) pairs from a question_log's citations. Idempotent."
  @spec record_citations(map()) :: {:ok, non_neg_integer()}
  def record_citations(%{citations: citations} = ql) when is_list(citations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> distinct_covered_pairs()
      |> Enum.map(fn {doc_id, page} ->
        %{
          document_id: doc_id,
          page: page,
          first_covered_by_user_id: Map.get(ql, :user_id),
          first_question_log_id: Map.get(ql, :id),
          first_covered_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(PageCoverage, rows,
        on_conflict: :nothing,
        conflict_target: [:document_id, :page]
      )

    {:ok, count}
  end

  def record_citations(_), do: {:ok, 0}

  @doc "Record a user's personal page exposure from a grounded answer's citations. Idempotent."
  @spec record_personal(integer() | nil, [map()]) :: {:ok, non_neg_integer()}
  def record_personal(user_id, citations) when is_integer(user_id) and is_list(citations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> distinct_covered_pairs()
      |> Enum.map(fn {doc_id, page} ->
        %{
          user_id: user_id,
          document_id: doc_id,
          page: page,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(UserPageCoverage, rows,
        on_conflict: :nothing,
        conflict_target: [:user_id, :document_id, :page]
      )

    {:ok, count}
  end

  def record_personal(_user_id, _citations), do: {:ok, 0}

  # Shared: distinct valid (document_id, page) pairs from a citation list,
  # clamped to page_count, unknown documents skipped. Used by both the
  # community (record_citations) and personal (record_personal) write paths.
  defp distinct_covered_pairs(citations) when is_list(citations) do
    page_counts = page_count_map(citations)

    citations
    |> Enum.flat_map(&covered_pair(&1, page_counts))
    |> Enum.uniq()
  end

  # Page-count lookup for the documents referenced by these citations.
  defp page_count_map(citations) do
    ids = citations |> Enum.map(& &1["document_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from d in Document, where: d.id in ^ids, select: {d.id, d.page_count})
    |> Map.new()
  end

  defp covered_pair(%{"document_id" => doc_id, "page" => page}, page_counts)
       when is_integer(doc_id) and is_integer(page) and page >= 1 do
    case Map.fetch(page_counts, doc_id) do
      # unknown document: skip
      :error -> []
      # beyond denominator: skip
      {:ok, pc} when is_integer(pc) and page > pc -> []
      # in-range, or nil page_count still records the page
      {:ok, _} -> [{doc_id, page}]
    end
  end

  defp covered_pair(_, _), do: []

  @doc """
  Coverage snapshot for a single document: `page_count`, distinct pages
  covered (capped at `page_count`), and `pct` (nil when `page_count` nil).
  """
  @spec for_document(integer()) :: %{
          page_count: integer() | nil,
          covered: non_neg_integer(),
          pct: float() | nil
        }
  def for_document(document_id) do
    page_count =
      Repo.one(from d in Document, where: d.id == ^document_id, select: d.page_count)

    covered_raw =
      Repo.aggregate(from(p in PageCoverage, where: p.document_id == ^document_id), :count)

    summarize(page_count, covered_raw)
  end

  @doc """
  Coverage rollup for a game: published documents for the game plus its
  expansions. `pending_review` (and any other non-`"published"`) documents
  are excluded.
  """
  @spec for_game(integer()) :: %{
          sources: [
            %{
              document_id: integer(),
              label: String.t() | nil,
              page_count: integer() | nil,
              covered: non_neg_integer(),
              pct: float() | nil
            }
          ],
          covered: non_neg_integer(),
          total: non_neg_integer(),
          pct: float() | nil
        }
  def for_game(game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{document_id: d.id, label: d.label, page_count: d.page_count}
      )

    document_ids = Enum.map(docs, & &1.document_id)

    counts =
      Repo.all(
        from p in PageCoverage,
          where: p.document_id in ^document_ids,
          group_by: p.document_id,
          select: {p.document_id, count(p.id)}
      )
      |> Map.new()

    sources =
      Enum.map(docs, fn d ->
        s = summarize(d.page_count, Map.get(counts, d.document_id, 0))
        Map.merge(d, s)
      end)

    total = sources |> Enum.map(&(&1.page_count || 0)) |> Enum.sum()
    covered = sources |> Enum.map(fn s -> if s.page_count, do: s.covered, else: 0 end) |> Enum.sum()

    %{sources: sources, covered: covered, total: total, pct: pct(covered, total)}
  end

  @doc "A user's personal coverage rollup across the game's published docs + expansions."
  def personal_for_game(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{document_id: d.id, page_count: d.page_count}
      )

    doc_ids = Enum.map(docs, & &1.document_id)

    counts =
      Repo.all(
        from u in UserPageCoverage,
          where: u.user_id == ^user_id and u.document_id in ^doc_ids,
          group_by: u.document_id,
          select: {u.document_id, count(u.id)}
      )
      |> Map.new()

    summaries =
      Enum.map(docs, fn d -> summarize(d.page_count, Map.get(counts, d.document_id, 0)) end)

    total = summaries |> Enum.map(&(&1.page_count || 0)) |> Enum.sum()

    covered =
      summaries |> Enum.map(fn s -> if s.page_count, do: s.covered, else: 0 end) |> Enum.sum()

    %{covered: covered, total: total, pct: pct(covered, total)}
  end

  @tier_order [:student, :scholar, :expert, :sage]
  @tier_names %{student: "Student", scholar: "Scholar", expert: "Expert", sage: "Sage"}
  # Raw-% thresholds for the lower tiers; Sage is set-based so no page target.
  @tier_threshold %{student: 0.25, scholar: 0.50, expert: 0.75}

  @doc "Display name for a tier atom, e.g. :student -> \"Student\". nil -> nil."
  def tier_name(tier), do: Map.get(@tier_names, tier)

  @doc "A user's per-game title derived from personal coverage vs the community-covered set."
  def title_for(user_id, game_id) do
    personal = personal_for_game(user_id, game_id)
    sage? = sage?(user_id, game_id)
    tier = tier_for(personal.pct, sage?)

    game_name =
      case Games.get_game(game_id) do
        nil -> nil
        g -> g.name
      end

    %{
      tier: tier,
      label: label_for(tier, game_name),
      pct: personal.pct,
      next_tier: next_tier(tier),
      pages_to_next: pages_to_next(tier, personal)
    }
  end

  # Sage: the user's personal page set covers 100% of the community-covered set (non-empty).
  defp sage?(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    doc_ids =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    community =
      Repo.all(
        from p in PageCoverage,
          where: p.document_id in ^doc_ids,
          select: {p.document_id, p.page}
      )
      |> MapSet.new()

    if MapSet.size(community) == 0 do
      false
    else
      personal =
        Repo.all(
          from u in UserPageCoverage,
            where: u.user_id == ^user_id and u.document_id in ^doc_ids,
            select: {u.document_id, u.page}
        )
        |> MapSet.new()

      MapSet.subset?(community, personal)
    end
  end

  defp tier_for(nil, _sage?), do: nil
  defp tier_for(_pct, true), do: :sage
  defp tier_for(pct, _sage?) when pct >= 0.75, do: :expert
  defp tier_for(pct, _sage?) when pct >= 0.50, do: :scholar
  defp tier_for(pct, _sage?) when pct >= 0.25, do: :student
  defp tier_for(_pct, _sage?), do: nil

  defp label_for(nil, _name), do: nil
  defp label_for(_tier, nil), do: nil
  defp label_for(tier, name), do: "#{name} #{@tier_names[tier]}"

  defp next_tier(:sage), do: nil

  defp next_tier(nil), do: :student

  defp next_tier(tier) do
    idx = Enum.find_index(@tier_order, &(&1 == tier))
    Enum.at(@tier_order, idx + 1)
  end

  defp pages_to_next(:sage, _personal), do: nil
  defp pages_to_next(_tier, %{pct: nil}), do: nil
  defp pages_to_next(_tier, %{total: 0}), do: nil

  defp pages_to_next(tier, %{covered: covered, total: total}) do
    case next_tier(tier) do
      :sage -> nil
      nil -> nil
      nt -> max(0, ceil(@tier_threshold[nt] * total) - covered)
    end
  end

  @doc "Uncovered pages across the game's published docs, enriched with a text snippet."
  def gaps_enriched(game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    docs =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    Enum.flat_map(docs, fn doc_id ->
      snippets = page_snippets(doc_id)

      doc_id
      |> gaps()
      |> Enum.map(fn page ->
        {label, snippet} = Map.get(snippets, page, {nil, nil})
        %{document_id: doc_id, page: page, label: label, snippet: snippet}
      end)
    end)
  end

  # For each page_number in a document: {section_label, first_line_of_content}
  # taken from the lowest chunk_index chunk on that page.
  defp page_snippets(doc_id) do
    Repo.all(
      from c in Chunk,
        where: c.document_id == ^doc_id and not is_nil(c.page_number),
        order_by: [asc: c.page_number, asc: c.chunk_index],
        select: {c.page_number, c.section_label, c.content}
    )
    |> Enum.reduce(%{}, fn {page, label, content}, acc ->
      Map.put_new(acc, page, {label, first_line(content)})
    end)
  end

  defp first_line(nil), do: nil

  defp first_line(content) do
    content |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end

  @doc "How many pages this user was first to ground, across the game's published docs."
  def contribution_credit(user_id, game_id) do
    game_ids = [game_id | expansion_game_ids(game_id)]

    doc_ids =
      Repo.all(
        from d in Document,
          where: d.game_id in ^game_ids and d.status == "published",
          select: d.id
      )

    Repo.aggregate(
      from(p in PageCoverage,
        where: p.document_id in ^doc_ids and p.first_covered_by_user_id == ^user_id
      ),
      :count
    )
  end

  @doc """
  Sorted list of uncovered page numbers in `1..page_count` for a document.
  Returns `[]` when `page_count` is nil.
  """
  @spec gaps(integer()) :: [integer()]
  def gaps(document_id) do
    page_count =
      Repo.one(from d in Document, where: d.id == ^document_id, select: d.page_count)

    case page_count do
      pc when is_integer(pc) and pc > 0 ->
        covered =
          Repo.all(from p in PageCoverage, where: p.document_id == ^document_id, select: p.page)
          |> MapSet.new()

        Enum.reject(1..pc, &MapSet.member?(covered, &1))

      _ ->
        []
    end
  end

  # page_count nil => pct nil, covered reported as-is (nothing to cap against).
  defp summarize(nil, covered_raw), do: %{page_count: nil, covered: covered_raw, pct: nil}

  defp summarize(page_count, covered_raw) when is_integer(page_count) do
    covered = min(covered_raw, page_count)
    %{page_count: page_count, covered: covered, pct: pct(covered, page_count)}
  end

  defp pct(_covered, 0), do: nil
  defp pct(covered, total), do: covered / total

  defp expansion_game_ids(game_id) do
    case Games.get_game(game_id) do
      nil -> []
      game -> game |> Games.expansions_for() |> Enum.map(& &1.id)
    end
  end
end
