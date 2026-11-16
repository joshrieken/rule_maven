defmodule RuleMaven.PdfCompress do
  @moduledoc """
  Shrinks stored rulebook PDFs by downsampling embedded images to the
  pipeline's render resolution (Ghostscript `pdfwrite`).

  Publisher PDFs are print masters: Gloomhaven's 52 pages carry 4,121 images
  averaging 326 ppi (max 3,667), 206 MB → 72 MB here. Nothing downstream
  reads past 300 dpi (`RulebookDownloader` renders pages at 300), so pixels
  above that are dead weight.

  Safety:
    * `-dAutoRotatePages=/None`: Ghostscript otherwise rotates pages to match
      text direction, which would break page renders and 2-up crops.
    * The result replaces the original only when it has the same page count
      and is at least 10% smaller; the swap is an atomic rename, so a reader
      mid-extraction keeps the old inode.
    * No Ghostscript on PATH (local dev) → skipped, never an error.
    * Runs on admin uploads only (`GameLive.Form` is admin-gated), as uid 1000
      with no capabilities in production, with `-dSAFER`.

  `file_hash` keeps the ORIGINAL upload's hash on purpose: it is the dedupe key
  for re-uploads of the same file (`Games.create_document/2`).
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias RuleMaven.Games.Document
  alias RuleMaven.Repo
  alias RuleMaven.Uploads

  @dpi 300
  @keep_ratio 0.9

  @doc """
  Compresses `doc`'s PDF in place and records the new `file_size`.
  Returns `{:ok, %{before: bytes, after: bytes}}` or `{:skipped, reason}`.
  """
  def compress_document(%Document{pdf_path: rel} = doc) when is_binary(rel) do
    with {:ok, sizes} <- compress_file(Uploads.resolve(rel)) do
      doc |> Ecto.Changeset.change(file_size: sizes.after) |> Repo.update()
      {:ok, sizes}
    end
  end

  def compress_document(_doc), do: {:skipped, :no_pdf}

  @doc "Compresses the PDF at absolute `path` in place (see moduledoc for the guards)."
  def compress_file(path) do
    with {:ok, gs} <- find(gs_executable()),
         {:ok, %{size: before}} <- File.stat(path),
         {:ok, pages} <- page_count(path) do
      tmp = path <> ".compress.tmp"

      try do
        with :ok <- run_gs(gs, path, tmp),
             {:ok, ^pages} <- page_count(tmp),
             {:ok, %{size: smaller}} when smaller <= before * @keep_ratio <- File.stat(tmp),
             :ok <- File.rename(tmp, path) do
          {:ok, %{before: before, after: smaller}}
        else
          {:ok, other_pages} when is_integer(other_pages) -> {:skipped, :page_count_changed}
          {:ok, %File.Stat{}} -> {:skipped, :not_smaller}
          {:error, reason} -> {:skipped, reason}
        end
      after
        File.rm(tmp)
      end
    else
      {:error, reason} -> {:skipped, reason}
      skipped -> skipped
    end
  end

  @doc """
  Compresses every stored PDF (production backfill; releases have no mix):

      bin/rule_maven rpc "RuleMaven.PdfCompress.backfill() |> IO.inspect()"

  Sequential on purpose: Ghostscript is CPU-heavy and this shares the box.
  """
  def backfill do
    from(d in Document, where: not is_nil(d.pdf_path), order_by: d.id)
    |> Repo.all()
    |> Enum.reduce(%{compressed: 0, skipped: 0, saved_bytes: 0}, fn doc, acc ->
      case compress_document(doc) do
        {:ok, %{before: b, after: a}} ->
          Logger.info("PdfCompress: document #{doc.id} #{b} → #{a} bytes")
          %{acc | compressed: acc.compressed + 1, saved_bytes: acc.saved_bytes + b - a}

        {:skipped, _reason} ->
          %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp run_gs(gs, src, dest) do
    args =
      ~w(-q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dCompatibilityLevel=1.6
         -dAutoRotatePages=/None
         -dDownsampleColorImages=true -dDownsampleGrayImages=true -dDownsampleMonoImages=true
         -dColorImageDownsampleThreshold=1.0 -dGrayImageDownsampleThreshold=1.0
         -dMonoImageDownsampleThreshold=1.0
         -dAutoFilterColorImages=false -dAutoFilterGrayImages=false
         -dColorImageFilter=/DCTEncode -dGrayImageFilter=/DCTEncode -dJPEGQ=90) ++
        [
          "-dColorImageResolution=#{@dpi}",
          "-dGrayImageResolution=#{@dpi}",
          "-dMonoImageResolution=#{@dpi * 2}",
          "-sOutputFile=#{dest}",
          src
        ]

    case System.cmd(gs, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:gs_exit, code, String.slice(out, 0, 200)}}
    end
  end

  defp page_count(path) do
    with {:ok, pdfinfo} <- find("pdfinfo"),
         {out, 0} <- System.cmd(pdfinfo, [path], stderr_to_stdout: true),
         [_, n] <- Regex.run(~r/^Pages:\s+(\d+)/m, out) do
      {:ok, String.to_integer(n)}
    else
      _ -> {:error, :unreadable_pdf}
    end
  end

  # Configurable so tests can point at a missing binary.
  defp gs_executable, do: Application.get_env(:rule_maven, :ghostscript, "gs")

  defp find(name) do
    case System.find_executable(name) do
      nil -> {:skipped, {:missing, name}}
      path -> {:ok, path}
    end
  end
end
