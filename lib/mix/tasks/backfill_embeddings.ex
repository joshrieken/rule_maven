defmodule Mix.Tasks.RuleMaven.BackfillEmbeddings do
  @shortdoc "Backfill embeddings for existing chunks"
  @moduledoc """
  Generates embeddings for all chunks that don't have them.

      mix rule_maven.backfill_embeddings
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.Repo

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    chunks =
      Repo.all(
        from c in RuleMaven.Games.Chunk,
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
        texts = Enum.map(batch, & &1.content)

        case RuleMaven.Embed.embed_batch(texts) do
          {:ok, vectors} ->
            batch
            |> Enum.zip(vectors)
            |> Enum.each(fn {chunk, vec} ->
              RuleMaven.Games.Chunk.changeset(chunk, %{embedding: vec})
              |> Repo.update!()
            end)

            Mix.shell().info("  Batch #{batch_idx}: #{length(batch)} chunks")

          {:error, reason} ->
            Mix.shell().error("  Batch #{batch_idx} failed: #{reason}")
        end

        Process.sleep(500)
      end)

      Mix.shell().info("Done.")
    end
  end
end
