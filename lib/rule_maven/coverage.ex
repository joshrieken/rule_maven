defmodule RuleMaven.Coverage do
  @moduledoc """
  Rulebook Coverage Engine context: resolves citation source labels to
  published `RuleMaven.Games.Document` ids.
  """

  import Ecto.Query

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
end
