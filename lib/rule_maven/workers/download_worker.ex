defmodule RuleMaven.Workers.DownloadWorker do
  @moduledoc """
  Durable rulebook download + text extraction. Fetches a PDF (by URL or by
  asking the LLM to find one), extracts its text, and persists a rulebook
  source (Document). Broadcasts `{:download_done, game_id, pdf_path}` or
  `{:download_error, game_id, reason}` on `topic/1` so the game form reloads
  its sources live.

  Replaces inline work in the LiveView process: a server restart mid-download
  no longer strands the spinner — Oban re-runs the orphaned job. `unique` keeps
  one *in-flight download of a given mode* per game at a time (the form disables
  the buttons that share a mode while running). Keying on `:game_id` alone would
  coalesce distinct concurrent batches — e.g. a "find" search and a fresh
  "upload" batch — into a single job, silently dropping one of them.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:game_id, :mode],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  alias RuleMaven.{Games, Jobs, Settings, RulebookDownloader}

  @worker "RuleMaven.Workers.DownloadWorker"
  @active_states ~w(available scheduled executing retryable suspended)

  def topic(game_id), do: "download:#{game_id}"

  # Upper bound on a single attempt regardless of where it wedges (network or a
  # subprocess). The downloader has its own finer-grained timeouts; this is the
  # backstop that guarantees the job — and the UI spinner — can't run forever.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # Human-readable label for each download stage, broadcast to the form.
  defp stage_label(:searching), do: "Searching for rulebook…"
  defp stage_label(:fetching), do: "Downloading PDF…"
  defp stage_label(:extracting), do: "Extracting text…"
  defp stage_label(:ocr), do: "Scanned PDF — running OCR (this can take a while)…"
  defp stage_label(:finalizing), do: "Saving rulebook…"
  defp stage_label(_), do: "Downloading…"

  @doc "True when a download job for this game is queued or running."
  def running?(game_id) do
    RuleMaven.Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
    )
  end

  @doc """
  Cancels any queued/running download job for this game so a wedged or unwanted
  download can be cleared and re-tried. No-op in test (Oban unsupervised).
  """
  def cancel(game_id) do
    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      query =
        from j in Oban.Job,
          where:
            j.worker == ^@worker and j.state in ^@active_states and
              fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))

      Oban.cancel_all_jobs(query)
    end

    Settings.delete("download_error_#{game_id}")
    :ok
  end

  @doc "Enqueue a download (no-op in test where Oban isn't supervised)."
  def enqueue(game_id, mode, url \\ nil, label \\ "") do
    Settings.delete("download_error_#{game_id}")

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id, mode: mode, url: url, label: label}
      |> new()
      |> Oban.insert()
    else
      :ok
    end
  end

  @doc """
  Enqueue extraction of one or more already-saved uploaded PDFs. `files` is a
  list of `%{pdf_path:, label:}` (static-relative paths under priv/static). Runs
  through the same durable, timeout-guarded pipeline as URL downloads — so
  scanned PDFs OCR in the background instead of blocking the LiveView. A single
  job handles the whole batch (unique per game).
  """
  def enqueue_upload(game_id, files) do
    Settings.delete("download_error_#{game_id}")

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id, mode: "upload", files: files}
      |> new()
      |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id} = args}) do
    game = Games.get_game!(game_id)
    label = Map.get(args, "label", "")

    # One run per attempt — an Oban restart re-runs perform from the top and
    # opens a fresh run, so the panel reflects the actual (re)attempt.
    run = Jobs.start_run("download", {"game", game_id}, game.name, oban_job_id: oban_id)
    Jobs.event(run, "info", "Starting…")

    on_progress = fn
      # Detailed per-page / per-step line for the progress log.
      {:log, text, kind} ->
        Jobs.event(run, to_string(kind), text)

      # Coarse stage → drives the banner spinner, and also a log line.
      stage ->
        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:download_progress, game_id, stage_label(stage)}
        )

        Jobs.event(run, "info", stage_label(stage))
    end

    result =
      try do
        case Map.get(args, "mode") do
          "url" -> RulebookDownloader.download(game, Map.get(args, "url"), label, on_progress)
          "find" -> RulebookDownloader.find_and_download(game, label, on_progress)
          "upload" -> ingest_uploads(game, Map.get(args, "files", []), on_progress)
        end
      rescue
        e ->
          require Logger
          Logger.error("Download crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
          {:error, "Download failed: #{Exception.message(e)}"}
      end

    case result do
      {:ok, source} ->
        Jobs.finish_run(run, "done", "Saved “#{source.label}”.")

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:download_done, game_id, source.pdf_path}
        )

        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", "Failed — #{reason}")
        Settings.put("download_error_#{game_id}", reason)

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:download_error, game_id, reason}
        )

        :ok
    end
  end

  # Extract a batch of uploaded PDFs in one job. Succeeds if at least one file
  # ingested; reports a combined error only when every file failed (so a single
  # bad PDF doesn't sink the rest of the batch).
  defp ingest_uploads(game, files, on_progress) do
    total = length(files)

    results =
      files
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} ->
        label = f["label"] || ""
        name = if label != "", do: label, else: Path.basename(f["pdf_path"] || "file")
        # Per-file header so a multi-file batch reads as distinct files, not one
        # run, and the result is attributed to the right file.
        on_progress.({:log, "File #{i}/#{total}: #{name}", :info})

        case RulebookDownloader.ingest_local(game, f["pdf_path"], label, on_progress) do
          {:ok, src} = ok ->
            on_progress.({:log, "Saved “#{src.label}”", :info})
            ok

          {:error, reason} = err ->
            on_progress.({:log, "Could not read #{name} — #{reason}", :error})
            err
        end
      end)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {[], []} ->
        {:error, "No files to extract"}

      {[], errors} ->
        {:error, errors |> Enum.map(fn {:error, r} -> r end) |> Enum.join("; ")}

      {[{:ok, source} | _], _errors} ->
        {:ok, source}
    end
  end
end
