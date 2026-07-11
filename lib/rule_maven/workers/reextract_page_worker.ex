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
    queue: :reextract,
    max_attempts: 3,
    unique: [
      keys: [:document_id, :page_index],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  require Logger
  alias RuleMaven.{Games, Jobs, RulebookDownloader}

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
  def perform(%Oban.Job{id: oban_id, args: %{"document_id" => doc_id, "page_index" => index}}) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{doc.game_id}"

    # One run per page (each page is its own Oban job), so the panel lists them
    # separately. Durable, so a refresh/restart keeps the lines.
    run =
      Jobs.start_run("reextract", {"document", doc_id}, "#{doc.label} — page #{index}",
        oban_job_id: oban_id
      )

    log = fn text, kind -> Jobs.event(run, kind, text) end

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
            label =
              cond do
                # Two-up: page.sheet is the logical page index; name the
                # physical sheet + half so the log matches the PDF viewer.
                doc.two_up ->
                  {phys, half} = RuleMaven.Extract.TwoUp.map_page(page.sheet)
                  "page #{page.printed || page.sheet} (sheet #{phys}, #{half} half)"

                page.printed ->
                  "sheet #{page.sheet} (page #{page.printed})"

                true ->
                  "sheet #{page.sheet}"
              end

            log.("Re-extracting #{label} with the stronger model…", "info")

            case RulebookDownloader.reextract_page(doc.pdf_path, page.sheet,
                   on_log: log,
                   label: label,
                   game_id: doc.game_id,
                   two_up: doc.two_up
                 ) do
              {:ok, result} ->
                case Games.replace_page(doc, index, result) do
                  {:error, :empty_extraction} ->
                    # The page kept its existing text rather than being blanked.
                    Logger.warning("Re-extract page #{index} produced empty text — page kept")

                    log.(
                      "Failed — #{label}: re-extraction produced no text; the existing text was kept.",
                      "error"
                    )

                    {:error, "empty extraction"}

                  _ ->
                    log.(
                      "Done — #{label} re-extracted (confidence #{fmt_conf(page.confidence)} → #{fmt_conf(result[:confidence])}).",
                      "done"
                    )

                    :ok
                end

              {:error, reason} ->
                Logger.warning("Re-extract page #{index} failed: #{reason}")
                log.("Failed — #{label}: #{reason}.", "error")
                {:error, to_string(reason)}
            end
        end
      rescue
        e ->
          Logger.error("Re-extract page #{index} crashed: #{Exception.message(e)}")
          log.("Failed — internal error.", "error")
          {:error, "internal error"}
      end

    case outcome do
      {:error, reason} -> Jobs.finish_run(run, "failed", "Page #{index}: #{reason}")
      _ -> Jobs.finish_run(run, "done", "Page #{index} re-extracted.")
    end

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      topic,
      {:reextract_done, doc_id, index, outcome}
    )

    :ok
  end

  defp fmt_conf(c) when is_number(c), do: :erlang.float_to_binary(c / 1, decimals: 2)
  defp fmt_conf(_), do: "—"
end
