defmodule RuleMaven.Coverage do
  @moduledoc """
  Rulebook Coverage Engine context: resolves citation source labels to
  published `RuleMaven.Games.Document` ids.
  """

  import Ecto.Query

  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Games
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
    page_counts = page_count_map(citations)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      citations
      |> Enum.flat_map(&covered_pair(&1, page_counts))
      |> Enum.uniq()
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

  # Page-count lookup for the documents referenced by these citations.
  defp page_count_map(citations) do
    ids = citations |> Enum.map(& &1["document_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from d in Document, where: d.id in ^ids, select: {d.id, d.page_count})
    |> Map.new()
  end

  defp covered_pair(%{"document_id" => doc_id, "page" => page}, page_counts)
       when is_integer(doc_id) and is_integer(page) and page >= 1 do
    case Map.get(page_counts, doc_id) do
      # beyond denominator: skip
      pc when is_integer(pc) and page > pc -> []
      # nil page_count still records the page
      _ -> [{doc_id, page}]
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
    covered = sources |> Enum.map(& &1.covered) |> Enum.sum()

    %{sources: sources, covered: covered, total: total, pct: pct(covered, total)}
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
