defmodule RuleMaven.Workers.ExtractWorker do
  @moduledoc """
  Durable, on-demand rulebook text extraction.

  Ingest now saves a source without extracting it (`RulebookDownloader.save_source`),
  so a rulebook lands as a `Document` with `pages: []`. This worker runs the
  vision/OCR extraction pipeline for one such document, fills its pages via
  `RulebookDownloader.extract_document/2`, and reports to the unified Jobs log.

  Finishing the run (kind `"extract"`) advances the readiness pipeline centrally
  from `Jobs.finish_run/3`, so a successful extraction flows on to cleanup →
  embed → enrichment without this worker knowing the next step.

  `unique` keeps at most one active job per document, so the prepare page's
  Extract button and the auto pipeline can't spawn parallel extractors.
  """
  use Oban.Worker,
    queue: :ingest,
    max_attempts: 3,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, RulebookDownloader}

  # Extraction (OCR for scanned PDFs) can take minutes; this is the hard backstop.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"document_id" => doc_id}}) do
    case Games.get_document(doc_id) do
      nil ->
        # Document deleted before the job ran — nothing to extract.
        :ok

      doc ->
        run =
          Jobs.start_run("extract", {"document", doc_id}, "Extract — #{doc.label}",
            oban_job_id: oban_id
          )

        Jobs.event(run, "info", "Extracting text…")

        on_progress = fn
          {:log, text, kind} -> Jobs.event(run, to_string(kind), text)
          stage -> Jobs.event(run, "info", stage_label(stage))
        end

        case RulebookDownloader.extract_document(doc, on_progress) do
          {:ok, updated} ->
            if RuleMaven.LLM.budget_exceeded?() do
              halt_over_budget(run, updated)
            else
              # A doc saved before extraction skipped the insert-time auto-publish
              # quality check; re-run it now so the doc doesn't sit pending_review
              # (and thus invisible to retrieval) after a clean extraction.
              case Games.maybe_auto_publish(updated) do
                {:ok, %{status: "published"}} when updated.status != "published" ->
                  Jobs.event(run, "info", "Quality check passed — auto-published.")

                _ ->
                  :noop
              end

              # finish_run (kind "extract") advances readiness centrally.
              Jobs.finish_run(run, "done", "Extracted #{length(updated.pages)} page(s).")
              :ok
            end

          {:error, reason} ->
            # Leave the doc unextracted so the prepare page still offers Extract;
            # return :ok (not an error) so Oban doesn't storm-retry a logical
            # failure — the admin re-runs it deliberately.
            Jobs.finish_run(run, "failed", "Extraction failed — #{reason}")
            :ok
        end
    end
  end

  # The document's LLM call budget ran out mid-extraction. Policy is stop and
  # mark for review, never silent truncation: keep every page already extracted,
  # hold the doc at pending_review so incomplete text can't reach retrieval, and
  # say so plainly in the Jobs log. Finishing "failed" (rather than "done") also
  # keeps the readiness pipeline from advancing to cleanup/embed on partial text.
  # An admin re-runs Extract to continue with a fresh budget.
  defp halt_over_budget(run, doc) do
    case Games.update_document(doc, %{status: "pending_review"}, chunk: false) do
      {:ok, _} -> :ok
      _ -> :ok
    end

    Jobs.event(
      run,
      "warn",
      "Extraction hit this document's LLM call budget — no further model calls were made."
    )

    Jobs.finish_run(
      run,
      "failed",
      "Stopped over budget — #{length(doc.pages)} page(s) kept, held for review. Re-run Extract to continue."
    )

    :ok
  end

  defp stage_label(:extracting), do: "Extracting text…"
  defp stage_label(:ocr), do: "Scanned PDF — running OCR (this can take a while)…"
  defp stage_label(:finalizing), do: "Saving extracted text…"
  defp stage_label(_), do: "Extracting…"
end
