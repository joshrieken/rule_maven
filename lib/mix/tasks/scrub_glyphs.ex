defmodule Mix.Tasks.RuleMaven.ScrubGlyphs do
  @shortdoc "Backfill: strip decorative extraction-artifact glyphs from stored text"
  @moduledoc """
  One-time cleanup of decorative icon glyphs (● ◧ ⛫ …) that the vision reader
  left in already-ingested text. `RuleMaven.Text.scrub_decorative/1` removes
  them going forward via `effective_page_text/1`; this task fixes rows that
  predate that.

    * Documents — rebuilds `full_text` from the (now-scrubbed) effective page
      text, re-chunks and re-embeds affected sources, and invalidates their
      answer pool. Raw page `text`/`cleaned` are left untouched (reversible).
    * Question log — scrubs stored `answer`, `cited_passage` and citation
      quotes in place.

  Idempotent. Re-embedding costs one embed batch per affected document.

      mix rule_maven.scrub_glyphs            # apply
      mix rule_maven.scrub_glyphs --dry-run  # report only
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Games, Repo, Text}
  alias RuleMaven.Games.{Document, QuestionLog}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dry_run? = "--dry-run" in args

    scrub_documents(dry_run?)
    scrub_question_log(dry_run?)
  end

  # Batch size for the keyset (id-window) loops below. `Repo.all(Document)`
  # used to load every rulebook — pages + full_text — into memory at once;
  # QuestionLog likewise loaded the whole table. Ops path, so plain and
  # obviously correct beats clever: walk ids in windows with narrow selects.
  @batch_size 100

  defp scrub_documents(dry_run?) do
    # The glyph check only needs full_text; pages are fetched (full row) only
    # for the affected docs, one at a time, when actually rewriting.
    fields = [:id, :label, :game_id, :full_text]

    {affected, total} =
      reduce_batches(Document, fields, {0, 0}, fn doc, {aff, tot} ->
        if Text.decorative?(doc.full_text) do
          scrub_document(doc, dry_run?)
          {aff + 1, tot + 1}
        else
          {aff, tot + 1}
        end
      end)

    Mix.shell().info("Documents: #{affected}/#{total} contain glyphs.")
  end

  # Raw page text/cleaned are left untouched (reversible), so idempotency keys
  # off the derived full_text, which the backfill rewrites glyph-free.
  defp scrub_document(summary, dry_run?) do
    if dry_run? do
      Mix.shell().info("  would scrub + re-embed source ##{summary.id} (#{summary.label})")
    else
      case Repo.get(Document, summary.id) do
        # Deleted since the window was read — skip.
        nil ->
          :ok

        doc ->
          new_full = Games.rebuild_full_text(doc.pages)
          Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [full_text: new_full])
          Games.chunk_document(doc)
          Games.invalidate_pool(doc.game_id)
          Mix.shell().info("  scrubbed + re-chunked source ##{doc.id} (#{doc.label})")
      end
    end
  end

  defp scrub_question_log(dry_run?) do
    fields = [:id, :answer, :cited_passage, :citations]

    {affected, total} =
      reduce_batches(QuestionLog, fields, {0, 0}, fn q, {aff, tot} ->
        case scrubbed_changes(q) do
          changes when changes == %{} ->
            {aff, tot + 1}

          changes ->
            unless dry_run? do
              Repo.update_all(
                from(r in QuestionLog, where: r.id == ^q.id),
                set: Map.to_list(changes)
              )
            end

            {aff + 1, tot + 1}
        end
      end)

    Mix.shell().info("Question log: #{affected}/#{total} rows contain glyphs.")
  end

  # Keyset loop: `WHERE id > last ORDER BY id LIMIT @batch_size`, selecting only
  # `fields`, folding `fun` over every row. Stable under concurrent inserts and
  # never holds more than one window in memory.
  defp reduce_batches(schema, fields, acc, fun), do: reduce_batches(schema, fields, 0, acc, fun)

  defp reduce_batches(schema, fields, last_id, acc, fun) do
    rows =
      Repo.all(
        from r in schema,
          where: r.id > ^last_id,
          order_by: r.id,
          limit: @batch_size,
          select: struct(r, ^fields)
      )

    case rows do
      [] ->
        acc

      rows ->
        acc = Enum.reduce(rows, acc, fun)
        reduce_batches(schema, fields, List.last(rows).id, acc, fun)
    end
  end

  # Builds a map of only the fields that actually carry a glyph.
  defp scrubbed_changes(%QuestionLog{} = q) do
    %{}
    |> put_if_glyph(:answer, q.answer)
    |> put_if_glyph(:cited_passage, q.cited_passage)
    |> put_citations_if_glyph(q.citations)
  end

  defp put_if_glyph(acc, key, value) do
    if Text.decorative?(value), do: Map.put(acc, key, Text.scrub_decorative(value)), else: acc
  end

  defp put_citations_if_glyph(acc, citations) when is_list(citations) do
    if Enum.any?(citations, fn c -> is_map(c) and Text.decorative?(c["quote"]) end),
      do: Map.put(acc, :citations, scrub_citations(citations)),
      else: acc
  end

  defp put_citations_if_glyph(acc, _), do: acc

  defp scrub_citations(citations) do
    Enum.map(citations, fn
      %{"quote" => quote} = c when is_binary(quote) ->
        Map.put(c, "quote", Text.scrub_decorative(quote))

      c ->
        c
    end)
  end
end
