defmodule RuleMaven.ManualImport do
  @moduledoc """
  Imports a rulebook whose pages were transcribed outside the app (by an admin
  reading the page images, e.g. Claude in a dev session) instead of by the
  extraction pipeline.

  Everything past the transcription goes through the normal app path —
  `Games.create_document/1` chunks it, enqueues embedding, invalidates the
  answer pool and queues the cheat sheet — so the result is indistinguishable
  from a pipeline-extracted source, except that its pages are marked
  `lane: "manual"` with full confidence and already cleaned (the transcription
  IS the clean copy), so the prepare pipeline goes straight to embedding.

  Input (`import/2`):

      %{
        "label" => "Core Rulebook",
        "kind" => "rulebook",                 # optional, default "rulebook"
        "pdf" => "/abs/or/relative/path.pdf",  # optional; copied into uploads
        "source_url" => "https://…",           # optional
        "pages" => [%{"sheet" => 1, "printed" => 1, "text" => "…"}, …]
      }
  """

  alias RuleMaven.{Games, Readiness, Uploads}
  alias RuleMaven.Games.Game

  @lane "manual"

  @doc "Import one transcribed document for `game`. Returns `{:ok, doc}` or `{:error, reason}`."
  def import(%Game{} = game, %{"pages" => [_ | _] = pages} = attrs) do
    with {:ok, pdf_path, file_hash} <- store_pdf(attrs["pdf"]),
         {:ok, pages} <- build_pages(pages) do
      result =
        Games.create_document(%{
          game_id: game.id,
          label: attrs["label"] || "Rulebook",
          kind: attrs["kind"] || "rulebook",
          source_url: attrs["source_url"],
          pdf_path: pdf_path,
          file_hash: file_hash,
          pages: pages,
          page_count: length(pages),
          full_text: Games.rebuild_full_text(pages),
          extracted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      with {:ok, _doc} <- result, do: Readiness.recompute(game)
      result
    end
  end

  def import(%Game{}, _attrs), do: {:error, :no_pages}

  # Copies the source PDF into the uploads dir under the same timestamped naming
  # the upload form uses, so the edit page's page viewer and re-extract work.
  defp store_pdf(nil), do: {:ok, nil, nil}

  defp store_pdf(src) do
    with {:ok, bin} <- File.read(src) do
      File.mkdir_p!(Uploads.resolve("uploads/rulebooks"))

      pdf_path =
        Path.join(
          "uploads/rulebooks",
          "#{System.system_time(:millisecond)}_#{Path.basename(src)}"
        )

      File.write!(Uploads.resolve(pdf_path), bin)
      {:ok, pdf_path, :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)}
    end
  end

  defp build_pages(pages) do
    pages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {page, i}, {:ok, acc} ->
      case page do
        %{"text" => text} when is_binary(text) and text != "" ->
          {:cont, {:ok, [page_attrs(page, i) | acc]}}

        _ ->
          {:halt, {:error, {:blank_page, i}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp page_attrs(page, i) do
    text = String.trim(page["text"])

    %{
      index: i,
      sheet: page["sheet"] || i + 1,
      printed: page["printed"],
      text: text,
      cleaned: text,
      confidence: 1.0,
      lane: @lane,
      source: @lane
    }
  end
end
