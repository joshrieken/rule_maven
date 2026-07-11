defmodule RuleMaven.Extract.TwoUp do
  @moduledoc """
  Pure geometry for 2-up documents — PDFs where each physical sheet carries two
  printed rulebook pages side by side (spread scans, print-and-play). Extraction
  treats such a book as `2 × sheets` logical pages; this module maps a logical
  page to its `{sheet, half}` and builds the poppler crop flags that isolate one
  half of a rendered sheet.

  Crop units: `pdftoppm -x/-y/-W/-H` are pixels at the requested `-r` dpi;
  `pdftotext` uses the same flags at its default 72 dpi, so pass `dpi: 72`
  there and the crop lands on the identical region of the page.
  """

  @doc """
  Maps a 1-based logical page number to its physical sheet and half.
  Logical 1 → `{1, :left}`, 2 → `{1, :right}`, 3 → `{2, :left}`, …
  """
  def map_page(logical) when is_integer(logical) and logical >= 1 do
    {div(logical + 1, 2), if(rem(logical, 2) == 1, do: :left, else: :right)}
  end

  @doc "Logical page count for a 2-up document with `sheets` physical sheets."
  def logical_count(sheets) when is_integer(sheets) and sheets >= 0, do: sheets * 2

  @doc """
  Poppler crop flags (`-x -y -W -H`) selecting one half of a sheet whose
  *rendered* size is `width_pts × height_pts`, at `dpi`. The right half absorbs
  any odd pixel so the two halves tile the sheet exactly. Callers must pass
  rotation-corrected dimensions (see `parse_sheet_size/2`) — poppler applies
  `/Rotate` before the pixel-space crop.
  """
  def crop_args(width_pts, height_pts, dpi, half) when half in [:left, :right] do
    w = round(width_pts * dpi / 72)
    h = round(height_pts * dpi / 72)
    half_w = div(w, 2)

    {x, crop_w} =
      case half do
        :left -> {0, half_w}
        :right -> {half_w, w - half_w}
      end

    ["-x", to_string(x), "-y", "0", "-W", to_string(crop_w), "-H", to_string(h)]
  end

  @doc """
  Parses one sheet's *rendered* size (points) out of `pdfinfo -f n -l n`
  output. pdfinfo reports the unrotated media box plus a separate `rot:` line,
  while pdftoppm/pdftotext render (and crop) after applying `/Rotate` — so a
  90/270 rotation swaps the reported width and height here, and callers can use
  the result directly for crop math. Returns `{:ok, {width_pts, height_pts}}`
  or `{:error, :no_size}`.
  """
  def parse_sheet_size(pdfinfo_out, sheet) when is_integer(sheet) do
    with [_, w, h] <-
           Regex.run(~r/^Page\s+#{sheet} size:\s+([\d.]+) x ([\d.]+) pts/m, pdfinfo_out) do
      rot =
        case Regex.run(~r/^Page\s+#{sheet} rot:\s+(\d+)/m, pdfinfo_out) do
          [_, r] -> String.to_integer(r)
          _ -> 0
        end

      {w, h} = {parse_float(w), parse_float(h)}
      if rem(rot, 180) == 90, do: {:ok, {h, w}}, else: {:ok, {w, h}}
    else
      _ -> {:error, :no_size}
    end
  end

  defp parse_float(s) do
    {f, _} = Float.parse(s)
    f
  end
end
