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

  alias RuleMaven.Games

  # LLM fan-out within a single job process; the writes back to the document are
  # funneled through Enum.each below, so they stay serialized (no embeds race).
  @max_concurrency 12

  @valid_levels ~w(light standard aggressive)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id, "game_id" => game_id} = args}) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{game_id}"
    level = parse_level(Map.get(args, "level"))
    mode = Map.get(args, "mode", "raw")

    # Which pages to (re)clean and what text to feed the cleaner:
    #   "raw"   — a fresh clean from the original extraction. enqueue_cleanup/3
    #             nulled all `cleaned` first, so todo is every page (a resumed
    #             run skips pages a prior attempt already persisted).
    #   "again" — a second pass over the *current* cleaned text to scrub leftover
    #             junk. Cleaned text is kept (it's the input), so reprocess every
    #             page and feed its effective (cleaned||text) copy.
    todo =
      if mode == "again", do: doc.pages, else: Enum.reject(doc.pages, &is_binary(&1.cleaned))

    total = length(doc.pages)
    # Resume from the durable counter so a restart continues the count instead of
    # restarting it (capped at total for "again", which reprocesses every page).
    start_done = doc.cleaning_done || 0

    # Progress is funneled through this serial Enum.reduce (the async fan-out is
    # above), so the counter increments without races. Each step persists the
    # page, advances the durable counter, and broadcasts {done, total} — the
    # single source of truth for the UI, realtime and after a refresh.
    todo
    |> Task.async_stream(
      fn page -> {page.index, clean_one(page, level, mode)} end,
      max_concurrency: @max_concurrency,
      ordered: false,
      timeout: :infinity,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce(start_done, fn
      {:ok, {index, {:ok, cleaned}}}, done ->
        done = min(done + 1, total)
        Games.set_page_cleaned(doc_id, index, cleaned)
        Games.set_cleaning_done(doc_id, done)

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic,
          {:page_cleaned, doc_id, index, cleaned, done, total}
        )

        done

      # LLM failed for this page: leave `cleaned` nil rather than baking the raw
      # text in. Retrieval/display already fall back to `text` (effective text =
      # cleaned||text), and the page stays eligible for a later re-clean instead
      # of looking permanently "cleaned" after a transient blip. Don't advance
      # the counter — it reflects pages actually persisted.
      {:ok, {_index, :failed}}, done ->
        done

      # A killed/exited task: same — leave it nil so a re-run retries it.
      {:exit, {_page, _reason}}, done ->
        done
    end)

    # Re-chunk once now that every page's effective text is final (per-page
    # writes skip chunking to avoid 21x re-embeds). Cleaned text now feeds
    # retrieval, so demote stale cached answers for the game.
    doc = Games.get_document!(doc_id)
    Games.chunk_document(doc)
    # Re-render the "View as HTML" file from the freshly cleaned text.
    Games.regenerate_document_html(doc)
    Games.invalidate_pool(doc.game_id)
    # Derived content (suggestions/facts/setup/categories) is intentionally NOT
    # regenerated here — that's the explicit finalize step, run once the admin is
    # satisfied with the cleaned source.

    # Clear the durable counter now the run is finished (idle = nil).
    Games.set_cleaning_done(doc_id, nil)
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:cleanup_done, doc_id})
    :ok
  end

  # Never let one page crash the job. Returns {:ok, cleaned} on success or
  # :failed on any error — the caller leaves failed pages' `cleaned` nil so they
  # can be retried, instead of persisting raw text as if it were cleaned.
  defp clean_one(page, level, mode) do
    # "again" re-cleans the current cleaned copy; "raw" cleans the original.
    body = if mode == "again", do: Games.effective_page_text(page), else: page.text || ""
    # The printed page number lives on the page separately — strip it from the
    # body (deterministic for isolated footers; the LLM handles glued cases).
    body = Games.strip_printed_number(body, page.printed)

    try do
      case RuleMaven.LLM.cleanup_page(body, level, page.printed) do
        {:ok, text} -> {:ok, text}
        {:error, _} -> :failed
      end
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  defp parse_level(level) when level in @valid_levels, do: String.to_existing_atom(level)
  defp parse_level(_), do: :light
end
