defmodule Mix.Tasks.RuleMaven.BackfillEmbeddings do
  @shortdoc "Backfill embeddings for existing chunks"
  @moduledoc """
  Generates embeddings for all chunks that don't have them.

      mix rule_maven.backfill_embeddings
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.Embed
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    chunks =
      Repo.all(
        from c in Chunk,
          where: is_nil(c.embedding),
          order_by: c.chunk_index
      )

    if chunks == [] do
      Mix.shell().info("All chunks already have embeddings.")
    else
      Mix.shell().info("Backfilling #{length(chunks)} chunks...")

      chunks
      |> Enum.chunk_every(10)
      |> Enum.with_index(1)
      |> Enum.each(fn {batch, batch_idx} ->
        backfill_batch(batch, batch_idx)
        Process.sleep(500)
      end)

      Mix.shell().info("Done.")
    end
  end

  defp backfill_batch(batch, batch_idx) do
    texts = Enum.map(batch, & &1.content)

    case Embed.embed_batch(texts) do
      {:ok, vectors} ->
        batch
        |> Enum.zip(vectors)
        |> Enum.each(fn {chunk, vec} ->
          chunk
          |> Chunk.changeset(%{embedding: vec})
          |> Repo.update!()
        end)

        Mix.shell().info("  Batch #{batch_idx}: #{length(batch)} chunks")

      {:error, reason} ->
        Mix.shell().error("  Batch #{batch_idx} failed: #{reason}")
    end
  end
end
