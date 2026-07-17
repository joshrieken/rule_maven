defmodule RuleMaven.Coverage do
  @moduledoc """
  Rulebook Coverage Engine context: resolves citation source labels to
  published `RuleMaven.Games.Document` ids.
  """

  import Ecto.Query

  alias RuleMaven.Coverage.PageCoverage
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
end
