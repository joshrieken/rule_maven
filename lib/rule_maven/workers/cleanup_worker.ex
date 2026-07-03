defmodule RuleMaven.Workers.CleanupWorker do
  @moduledoc """
  Durable, restart-survivable rulebook text cleanup.

  Cleans each page's extracted text via the LLM and writes the result straight
  into `Document.pages[].cleaned` as it finishes, broadcasting per page so the
  LiveView swaps that page live. Because each finished page is persisted
  immediately, a server restart loses no completed work: Oban re-runs the
  orphaned job, and `perform/1` only processes pages whose `cleaned` is still
  nil — so it resumes exactly where it left off.

  `unique` keeps at most one active job per document, so a double-click or a
  remount can't spawn parallel cleaners racing on the same embeds_many column.
  """
  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 5,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}

  # LLM fan-out within a single job process; the writes back to the document are
  # funneled through Enum.each below, so they stay serialized (no embeds race).
  @max_concurrency 12

  @valid_levels ~w(light standard aggressive)

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: oban_id,
        args: %{"document_id" => doc_id, "game_id" => game_id} = args
      }) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{game_id}"
    level = parse_level(Map.get(args, "level"))
    mode = Map.get(args, "mode", "raw")
    page_index = Map.get(args, "page_index")

    label =
      if is_integer(page_index),
        do: "Clean page #{page_index + 1} — #{doc.label}",
        else: "Clean up — #{doc.label}"

    run = Jobs.start_run("cleanup", {"document", doc_id}, label, oban_job_id: oban_id)

    # Which pages to (re)clean and what text to feed the cleaner:
    #   page_index — a single-page clean (enqueue_cleanup_page/3): just that
    #             page, always from its original extraction, cleaned or not.
    #   "raw"   — a fresh clean from the original extraction. enqueue_cleanup/3
    #             nulled all `cleaned` first, so todo is every page (a resumed
    #             run skips pages a prior attempt already persisted).
    #   "again" — a second pass over the *current* cleaned text to scrub leftover
    #             junk. Cleaned text is kept (it's the input), so reprocess every
    #             page and feed its effective (cleaned||text) copy.
    todo =
      cond do
        is_integer(page_index) -> Enum.filter(doc.pages, &(&1.index == page_index))
        mode == "again" -> doc.pages
        true -> Enum.reject(doc.pages, &is_binary(&1.cleaned))
      end

    # A page run's progress counts against just its own page, not the book.
    total = if is_integer(page_index), do: length(todo), else: length(doc.pages)
    # Resume from the durable counter so a restart continues the count instead of
    # restarting it (capped at total for "again", which reprocesses every page).
    start_done = doc.cleaning_done || 0

    # Opt-in adversarial check that cleanup didn't drop/alter rule content. Off by
    # default — it's a second LLM call per cleaned page.
    critic? = Settings.get("cleanup_critic") == "true"

    note = if critic?, do: " · critic on", else: ""

    Jobs.event(
      run,
      "info",
      "Cleaning #{length(todo)} of #{total} pages (#{mode}, #{level})#{note}…"
    )

    # Progress is funneled through this serial Enum.reduce (the async fan-out is
    # above), so the counter increments without races. Each step persists the
    # page, advances the durable counter, and broadcasts {done, total} — the
    # single source of truth for the UI, realtime and after a refresh.
    init = %{
      done: start_done,
      removed: 0,
      kept_raw: 0,
      unchanged: 0,
      cleaned: 0,
      failed: 0,
      flagged: 0
    }

    stats =
      todo
      |> Task.async_stream(
        fn page -> {page.index, clean_one(page, level, mode, critic?, game_id)} end,
        max_concurrency: @max_concurrency,
        ordered: false,
        timeout: :infinity,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.reduce(init, fn
        {:ok, {index, {:ok, cleaned, meta}}}, acc ->
          done = min(acc.done + 1, total)
          Games.set_page_cleaned(doc_id, index, cleaned)
          Games.set_cleaning_done(doc_id, done)
          Jobs.event(run, event_level(meta.status), page_event_msg(index, meta, done, total))

          defects = meta[:defects] || []

          if defects != [] do
            Jobs.event(
              run,
              "warn",
              "Page #{index + 1} — cleanup review flagged #{length(defects)} issue(s): #{Enum.join(defects, " | ")}"
            )
          end

          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            topic,
            {:page_cleaned, doc_id, index, cleaned, done, total}
          )

          acc
          |> Map.put(:done, done)
          |> Map.update!(:removed, &(&1 + max(meta.in - meta.out, 0)))
          |> Map.update!(:flagged, &(&1 + if(defects == [], do: 0, else: 1)))
          |> Map.update(meta.status, 1, &(&1 + 1))

        # LLM failed for this page: leave `cleaned` nil rather than baking the raw
        # text in. Retrieval/display already fall back to `text` (effective text =
        # cleaned||text), and the page stays eligible for a later re-clean instead
        # of looking permanently "cleaned" after a transient blip. Don't advance
        # the counter — it reflects pages actually persisted.
        {:ok, {index, :failed}}, acc ->
          Jobs.event(
            run,
            "warn",
            "Page #{index + 1} failed to clean — left as-is, will retry on re-clean"
          )

          Map.update!(acc, :failed, &(&1 + 1))

        # A killed/exited task: same — leave it nil so a re-run retries it.
        {:exit, {page, _reason}}, acc ->
          Jobs.event(
            run,
            "warn",
            "Page #{page.index + 1} timed out/crashed — left as-is, will retry on re-clean"
          )

          Map.update!(acc, :failed, &(&1 + 1))
      end)

    # Re-chunk only when the doc already has chunks (a re-clean of a live doc)
    # so the cleaned text reaches retrieval instead of leaving stale raw-text
    # chunks. A first-run cleanup deliberately does NOT chunk — embedding is
    # the next pipeline step and is triggered explicitly (prepare page button
    # or the auto pipeline), never as a side effect of cleanup.
    doc = Games.get_document!(doc_id)
    if Games.document_chunked?(doc_id), do: Games.chunk_document(doc)
    # Re-render the "View as HTML" file from the freshly cleaned text.
    Games.regenerate_document_html(doc)
    Games.invalidate_pool(doc.game_id)
    # Derived content (suggestions/facts/setup/categories) is intentionally NOT
    # regenerated here — that's the explicit finalize step, run once the admin is
    # satisfied with the cleaned source.

    # Clear the durable counter now the run is finished (idle = nil).
    Games.set_cleaning_done(doc_id, nil)

    Jobs.finish_run(run, "done", finish_summary(stats, total))
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:cleanup_done, doc_id})
    :ok
  end

  # Never let one page crash the job. Returns {:ok, cleaned, meta} on success or
  # :failed on any error — the caller leaves failed pages' `cleaned` nil so they
  # can be retried, instead of persisting raw text as if it were cleaned. `meta`
  # carries the in/out char counts and a status (:cleaned | :unchanged |
  # :kept_raw | :empty) so the job log can report what actually happened.
  defp clean_one(page, level, mode, critic?, game_id) do
    # "again" re-cleans the current cleaned copy; "raw" cleans the original.
    body = if mode == "again", do: Games.effective_page_text(page), else: page.text || ""
    # The printed page number lives on the page separately — strip it from the
    # body (deterministic for isolated footers; the LLM handles glued cases).
    body = Games.strip_printed_number(body, page.printed)

    try do
      case RuleMaven.LLM.cleanup_page(body, level, page.printed, game_id: game_id) do
        {:ok, text, status} ->
          meta = clean_meta(status, body, text)

          {:ok, text,
           Map.put(meta, :defects, maybe_critique(critic?, meta.status, body, text, game_id))}

        {:error, _} ->
          :failed
      end
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  # Only worth critiquing a page the model actually rewrote (:cleaned). An error
  # from the critic must never fail the page — fall back to "no defects".
  defp maybe_critique(true, :cleaned, body, text, game_id) do
    case RuleMaven.LLM.critique_cleanup(body, text, game_id: game_id) do
      {:ok, %{defects: defects}} -> defects
      {:error, _} -> []
    end
  end

  defp maybe_critique(_critic?, _status, _body, _text, _game_id), do: []

  # Per-page result detail for the job log. A model that returned its input
  # essentially unchanged is reported as :unchanged (distinct from :kept_raw,
  # where the drop guard *rejected* a too-short output).
  defp clean_meta(status, body, text) do
    in_len = String.length(body)
    out_len = String.length(text)

    status =
      cond do
        status in [:kept_raw, :empty] -> status
        String.trim(text) == String.trim(body) -> :unchanged
        true -> :cleaned
      end

    %{status: status, in: in_len, out: out_len}
  end

  defp event_level(:kept_raw), do: "warn"
  defp event_level(_), do: "info"

  defp page_event_msg(index, %{status: :cleaned} = m, done, total),
    do: "Cleaned page #{index + 1} — #{m.in}→#{m.out} chars (#{pct(m)}) · #{done}/#{total} done"

  defp page_event_msg(index, %{status: :unchanged}, done, total),
    do: "Page #{index + 1} — no changes · #{done}/#{total} done"

  defp page_event_msg(index, %{status: :kept_raw}, done, total),
    do: "Page #{index + 1} — cleaner output too short, kept raw · #{done}/#{total} done"

  defp page_event_msg(index, %{status: :empty}, done, total),
    do: "Page #{index + 1} — blank, nothing to clean · #{done}/#{total} done"

  # Signed percent change in length, e.g. "−7%" / "+2%" / "0%".
  defp pct(%{in: 0}), do: "—"

  defp pct(%{in: i, out: o}) do
    p = round((o - i) / i * 100)
    sign = if p > 0, do: "+", else: if(p < 0, do: "−", else: "")
    "#{sign}#{abs(p)}%"
  end

  defp finish_summary(stats, total) do
    cleaned = Map.get(stats, :cleaned, 0)

    notes =
      [
        stats.removed > 0 && "removed #{stats.removed} chars",
        Map.get(stats, :unchanged, 0) > 0 && "#{stats.unchanged} unchanged",
        Map.get(stats, :kept_raw, 0) > 0 && "#{stats.kept_raw} kept raw",
        Map.get(stats, :flagged, 0) > 0 && "#{stats.flagged} flagged for review",
        Map.get(stats, :failed, 0) > 0 && "#{stats.failed} failed"
      ]
      |> Enum.filter(& &1)

    base = "Cleaned #{cleaned}/#{total} pages + re-chunked"
    if notes == [], do: base <> ".", else: base <> " (" <> Enum.join(notes, ", ") <> ")."
  end

  defp parse_level(level) when level in @valid_levels, do: String.to_existing_atom(level)
  defp parse_level(_), do: :light
end
