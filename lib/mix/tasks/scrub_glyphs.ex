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

  defp scrub_documents(dry_run?) do
    docs = Repo.all(Document)

    # Raw page text/cleaned are left untouched (reversible), so idempotency keys
    # off the derived full_text, which the backfill rewrites glyph-free.
    affected = Enum.filter(docs, fn doc -> Text.decorative?(doc.full_text) end)

    Mix.shell().info("Documents: #{length(affected)}/#{length(docs)} contain glyphs.")

    Enum.each(affected, fn doc ->
      if dry_run? do
        Mix.shell().info("  would scrub + re-embed source ##{doc.id} (#{doc.label})")
      else
        new_full = Games.rebuild_full_text(doc.pages)
        Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [full_text: new_full])
        Games.chunk_document(doc)
        Games.invalidate_pool(doc.game_id)
        Mix.shell().info("  scrubbed + re-chunked source ##{doc.id} (#{doc.label})")
      end
    end)
  end

  defp scrub_question_log(dry_run?) do
    rows = Repo.all(QuestionLog)

    updates =
      rows
      |> Enum.map(fn q -> {q, scrubbed_changes(q)} end)
      |> Enum.reject(fn {_q, changes} -> changes == %{} end)

    Mix.shell().info("Question log: #{length(updates)}/#{length(rows)} rows contain glyphs.")

    unless dry_run? do
      Enum.each(updates, fn {q, changes} ->
        Repo.update_all(from(r in QuestionLog, where: r.id == ^q.id), set: Map.to_list(changes))
      end)
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
