defmodule RuleMaven.Workers.EmbedChunksWorker do
  @moduledoc """
  Generates embeddings for all chunks of a document.
  Enqueued after document creation, runs async so uploads don't block.
  """

  use Oban.Worker, queue: :default, max_attempts: 3
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Games

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id}}) do
    # Oban serializes args to JSON: an integer enqueued as `document_id` comes
    # back an integer, a string stays a string. Accept both — passing the raw
    # integer here used to crash `String.to_integer/1` and fail every embed job.
    doc_id = normalize_id(doc_id)
    doc = Games.get_document!(doc_id)

    chunks =
      Repo.all(
        from c in Games.Chunk,
          where: c.document_id == ^doc.id and is_nil(c.embedding),
          order_by: c.chunk_index
      )

    if chunks != [] do
      texts = Enum.map(chunks, & &1.content)

      case RuleMaven.Embed.embed_batch(texts) do
        {:ok, vectors} ->
          chunks
          |> Enum.zip(vectors)
          |> Enum.each(fn {chunk, vec} ->
            Games.Chunk.changeset(chunk, %{embedding: vec})
            |> Repo.update!()
          end)

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
end
