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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id, "game_id" => game_id}}) do
    doc = Games.get_document!(doc_id)
    topic = "game_cleanup:#{game_id}"

    # Resume point: only pages not yet written. A fresh run nulls all cleaned
    # text first (see Games.enqueue_cleanup/1), so this is every page; a resumed
    # run skips whatever the previous attempt already persisted.
    todo = Enum.reject(doc.pages, &is_binary(&1.cleaned))

    todo
    |> Task.async_stream(
      fn page -> {page.index, clean_one(page)} end,
      max_concurrency: @max_concurrency,
      ordered: false,
      timeout: :infinity,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.each(fn
      {:ok, {index, cleaned}} ->
        persist(doc_id, index, cleaned, topic)

      # A killed/exited task still resolves: keep the original page text so the
      # run completes and the page is marked done.
      {:exit, {page, _reason}} ->
        persist(doc_id, page.index, page.text || "", topic)
    end)

    # Re-chunk once now that every page's effective text is final (per-page
    # writes skip chunking to avoid 21x re-embeds). Cleaned text now feeds
    # retrieval, so demote stale cached answers for the game.
    doc = Games.get_document!(doc_id)
    Games.chunk_document(doc)
    Games.invalidate_pool(doc.game_id)

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:cleanup_done, doc_id})
    :ok
  end

  # Never let one page crash the job: on any failure keep the original text.
  defp clean_one(page) do
    body = page.text || ""

    try do
      case RuleMaven.LLM.cleanup_page(body) do
        {:ok, text} -> text
        {:error, _} -> body
      end
    rescue
      _ -> body
    catch
      _, _ -> body
    end
  end

  defp persist(doc_id, index, cleaned, topic) do
    Games.set_page_cleaned(doc_id, index, cleaned)
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic, {:page_cleaned, doc_id, index, cleaned})
  end
end
