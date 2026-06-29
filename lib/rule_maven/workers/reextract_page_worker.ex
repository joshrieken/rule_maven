defmodule RuleMaven.Workers.ReextractPageWorker do
  @moduledoc """
  Durable single-page re-extraction. Re-renders one page of a stored document and
  re-reads it at the top tier (strong/high-res model + adversarial critic), then
  persists the result. Triggered from the admin review UI for a low-confidence
  page. Broadcasts `{:reextract_done, document_id}` on the game's cleanup topic
  so the form reloads that source live.

  Runs through Oban (not a detached Task) so a server restart mid-extraction is
  retried rather than stranding the page. `unique` keeps one job per page.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:document_id, :page_index],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  require Logger
  alias RuleMaven.{Games, RulebookDownloader}

  @worker "RuleMaven.Workers.ReextractPageWorker"
  @active_states ~w(available scheduled executing retryable suspended)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc """
  True when a re-extraction job for this document is queued or running. Lets the
  form rebuild the per-source "busy" indicator from durable Oban state after a
  refresh/remount, instead of relying on in-memory flags.
  """
  def running?(document_id) do
    RuleMaven.Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'document_id' = ?", j.args, ^to_string(document_id))
    )
  end

  @doc "How many re-extraction jobs for this document are queued or running."
  def active_count(document_id) do
    RuleMaven.Repo.aggregate(
      from(j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'document_id' = ?", j.args, ^to_string(document_id))
      ),
      :count
    )
  end

  @doc "Enqueue a re-extraction (no-op in test where Oban isn't supervised)."
  def enqueue(document_id, page_index) do
    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{document_id: document_id, page_index: page_index}
      |> new()
      |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id, "page_index" => index}}) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{doc.game_id}"

    # Stream a live progress log to the form (transient, mirrors the upload log):
    # each stage of the re-extraction broadcasts one line on the cleanup topic.
    log = fn text, kind ->
      Phoenix.PubSub.broadcast(
        RuleMaven.PubSub,
        topic,
        {:reextract_log, doc_id, index, text, kind}
      )
    end

    # Always broadcast the outcome (success, failure, or raise) once the topic is
    # known, so the UI never gets stuck on "Re-extracting…" and can tell the user
    # honestly what happened. We swallow the error after reporting it rather than
    # retry — re-extraction is a best-effort, user-triggered action.
    outcome =
      try do
        case Enum.find(doc.pages, &(&1.index == index)) do
          nil ->
            :noop

          page ->
            log.("Re-extracting page #{page.printed || page.sheet} with the stronger model…", "info")

            case RulebookDownloader.reextract_page(doc.pdf_path, page.sheet, on_log: log) do
              {:ok, result} ->
                Games.replace_page(doc, index, result)
                log.("Done — page re-extracted and saved.", "done")
                :ok

              {:error, reason} ->
                Logger.warning("Re-extract page #{index} failed: #{reason}")
                log.("Failed — #{reason}.", "error")
                {:error, to_string(reason)}
            end
        end
      rescue
        e ->
          Logger.error("Re-extract page #{index} crashed: #{Exception.message(e)}")
          log.("Failed — internal error.", "error")
          {:error, "internal error"}
      end

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      topic,
      {:reextract_done, doc_id, index, outcome}
    )

    :ok
  end
end
