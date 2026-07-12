defmodule RuleMaven.Workers.EmbedChunksWorker do
  @moduledoc """
  Generates embeddings for all chunks of a document.
  Enqueued after document creation, runs async so uploads don't block.

  Chunks are embedded in sub-batches of 100, each persisted before the next
  starts — a big rulebook never rides one giant HTTP request into the provider's
  batch limit or the receive timeout, and a mid-run failure keeps every finished
  sub-batch (the `is_nil(embedding)` fetch makes the retry resume where it
  stopped).

  `unique` keeps at most one active job per document, mirroring ExtractWorker,
  so re-chunking and the auto pipeline can't spawn parallel embedders.
  """

  use Oban.Worker,
    queue: :ingest,
    max_attempts: 3,
    unique: [
      keys: [:document_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.{Games, Jobs}

  @embed_batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"document_id" => doc_id}}) do
    # Oban serializes args to JSON: an integer enqueued as `document_id` comes
    # back an integer, a string stays a string. Accept both — passing the raw
    # integer here used to crash `String.to_integer/1` and fail every embed job.
    doc_id = normalize_id(doc_id)

    case Games.get_document(doc_id) do
      nil ->
        # Document deleted before the job ran — nothing to embed.
        :ok

      doc ->
        embed_document(doc, oban_id)
    end
  end

  defp embed_document(doc, oban_id) do
    # Document-scoped run so the readiness pipeline (and the admin log) see embed
    # finish — `Jobs.finish_run/3` resolves the game and advances auto-prepare.
    run =
      Jobs.start_run("embed", {"document", doc.id}, "Embed chunks — #{doc.label}",
        oban_job_id: oban_id
      )

    chunks =
      Repo.all(
        from c in Games.Chunk,
          where: c.document_id == ^doc.id and is_nil(c.embedding),
          order_by: c.chunk_index
      )

    if chunks == [] do
      Jobs.finish_run(run, "done", "No chunks needed embedding.")
      :ok
    else
      case embed_in_batches(chunks) do
        :ok ->
          Jobs.finish_run(run, "done", "Embedded #{length(chunks)} chunk(s).")
          :ok

        {:error, reason} ->
          Jobs.finish_run(run, "failed", "Embedding failed — #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Embed and persist sub-batch by sub-batch. Persisting each sub-batch before
  # the next starts means a failure part-way through loses nothing already
  # done — the retry's `is_nil(embedding)` fetch skips persisted chunks.
  defp embed_in_batches(chunks) do
    chunks
    |> Enum.chunk_every(@embed_batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      texts = Enum.map(batch, & &1.content)

      case RuleMaven.Embed.embed_batch(texts) do
        {:ok, vectors} ->
          batch
          |> Enum.zip(vectors)
          |> Enum.each(fn {chunk, vec} ->
            Games.Chunk.changeset(chunk, %{embedding: vec})
            |> Repo.update!()
          end)

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
end
