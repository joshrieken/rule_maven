defmodule RuleMaven.Workers.PdfCompressWorker do
  @moduledoc """
  Shrinks a newly stored rulebook PDF (`RuleMaven.PdfCompress`). Enqueued by
  `Games.create_document/2` for every source with a PDF. Background because a
  print-master PDF takes minutes of Ghostscript; the `reextract` queue
  (concurrency 1) keeps it from crowding interactive work.
  """
  use Oban.Worker,
    queue: :reextract,
    max_attempts: 2,
    unique: [period: 3600, keys: [:document_id]]

  alias RuleMaven.Games.Document
  alias RuleMaven.{Jobs, PdfCompress, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"document_id" => id}}) do
    case Repo.get(Document, id) do
      nil ->
        :ok

      doc ->
        run = Jobs.start_run("pdf_compress", {"document", id}, doc.label, oban_job_id: oban_id)

        case PdfCompress.compress_document(doc) do
          {:ok, %{before: b, after: a}} ->
            summary = "#{mb(b)} → #{mb(a)} MB"
            Jobs.event(run, "done", "Compressed PDF: #{summary}")
            Jobs.finish_run(run, "done", summary)

          {:skipped, reason} ->
            Jobs.event(run, "info", "Left as is: #{inspect(reason)}")
            Jobs.finish_run(run, "done", "unchanged")
        end

        :ok
    end
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
