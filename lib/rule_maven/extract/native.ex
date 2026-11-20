defmodule RuleMaven.Extract.Native do
  @moduledoc """
  Native-text extraction lanes: docx/odt, html, xlsx, csv, txt/md. These formats
  carry their text losslessly, so they're read structurally with no OCR and no
  model call — the cheapest path to maximum accuracy. Each returns the same
  "\f"-joined-by-logical-page text the PDF path produces, so downstream
  pagination/markers/RAG are unchanged.

  The inner parsers (`docx_text/1`, `odt_text/1`, `html_to_text/1`,
  `csv_to_table/1`, `shared_strings/1`, `sheet_table/2`) are pure and unit-tested
  on raw fragments; the public `extract/1` wraps them with archive/file IO.
  """

  NimbleCSV.define(RuleMaven.Extract.Native.CSV, separator: ",", escape: "\"")

  alias RuleMaven.Extract.Native.CSV

  # Cap on total decompressed bytes for an office archive (docx/odt/xlsx) — guards
  # against a zip bomb expanding to gigabytes in memory. Rulebooks are far smaller.
  @max_unzip_bytes 200 * 1024 * 1024

  @doc """
  Extracts text from a native-format file. Returns `{:ok, text}` or
  `{:error, reason}`. `text` is "\f"-joined per logical page (one chunk for
  single-flow formats; one per sheet for xlsx).
  """
  def extract(path) do
    case ext(path) do
      e when e in ~w(.docx) -> from_zip(path, "word/document.xml", &docx_text/1)
      e when e in ~w(.odt) -> from_zip(path, "content.xml", &odt_text/1)
      e when e in ~w(.html .htm) -> with {:ok, b} <- File.read(path), do: {:ok, html_to_text(b)}
      e when e in ~w(.csv) -> with {:ok, b} <- File.read(path), do: {:ok, csv_to_table(b)}
      e when e in ~w(.txt .md .markdown) -> File.read(path)
      e when e in ~w(.xlsx) -> xlsx_text(path)
      other -> {:error, "unsupported native format: #{other}"}
    end
  end

  @doc "Lowercased file extension (incl. dot), or \"\" when none."
  def ext(path), do: path |> Path.extname() |> String.downcase()

  @doc "True for extensions handled by the native lanes (not pdf, not images)."
  def native?(path) do
    ext(path) in ~w(.docx .odt .html .htm .csv .txt .md .markdown .xlsx)
  end

  # --- docx / odt ---

  @doc "Plain text from a docx `word/document.xml` body (paragraphs → blank-line-separated)."
  def docx_text(xml) do
    xml
    |> String.split(~r{</w:p>})
    |> Enum.map(fn para ->
      Regex.scan(~r{<w:t[^>]*>(.*?)</w:t>}s, para)
      |> Enum.map_join("", fn [_, t] -> t end)
      |> decode_entities()
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc "Plain text from an odt `content.xml` (paragraphs/headings → blank-line-separated)."
  def odt_text(xml) do
    xml
    |> String.split(~r{</text:(?:p|h)>})
    |> Enum.map(fn para ->
      para |> strip_tags() |> decode_entities() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # --- html ---

  @doc "Readable text from an HTML document (scripts/styles dropped, blocks → newlines)."
  def html_to_text(html) do
    html
    |> String.replace(~r{<(script|style)[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</(p|div|h[1-6]|li|tr|table|section|article|header|footer)>}i, "\n")
    |> strip_tags()
    |> decode_entities()
    |> String.replace(~r{[ \t]+}, " ")
    |> String.replace(~r{\n[ \t]+}, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # --- csv ---

  @doc "A Markdown table from CSV text. Empty input → \"\"."
  def csv_to_table(binary) do
    rows = CSV.parse_string(binary, skip_headers: false)
    rows_to_markdown(rows)
  end

  # --- xlsx ---

  defp xlsx_text(path) do
    case unzip_all(path) do
      {:ok, files} ->
        shared = shared_strings(Map.get(files, "xl/sharedStrings.xml", ""))

        sheets =
          files
          |> Map.keys()
          |> Enum.filter(&Regex.match?(~r{^xl/worksheets/sheet\d+\.xml$}, &1))
          |> Enum.sort_by(&sheet_number/1)

        text =
          sheets
          |> Enum.map(fn name -> sheet_table(files[name], shared) end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\f")

        if String.trim(text) == "",
          do: {:error, "spreadsheet had no readable cells"},
          else: {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sheet_number(name) do
    case Regex.run(~r{sheet(\d+)\.xml$}, name) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  @doc "Shared-string table from xlsx `xl/sharedStrings.xml` (index → text)."
  def shared_strings(xml) do
    Regex.scan(~r{<si>(.*?)</si>}s, xml)
    |> Enum.map(fn [_, si] ->
      Regex.scan(~r{<t[^>]*>(.*?)</t>}s, si)
      |> Enum.map_join("", fn [_, t] -> t end)
      |> decode_entities()
    end)
  end

  @doc """
  Markdown table from one worksheet's XML, resolving shared-string cells against
  `shared`. Cells are ordered by spreadsheet column; gaps are ignored.
  """
  def sheet_table(sheet_xml, shared) do
    rows =
      Regex.scan(~r{<row[^>]*>(.*?)</row>}s, sheet_xml)
      |> Enum.map(fn [_, row] -> row_cells(row, shared) end)

    rows_to_markdown(rows)
  end

  defp row_cells(row, shared) do
    # Normalise self-closing empty cells so one regex captures both forms.
    row
    |> String.replace(~r{<c\b([^>]*)/>}, "<c\\1></c>")
    |> then(&Regex.scan(~r{<c\b([^>]*)>(.*?)</c>}s, &1))
    |> Enum.map(fn [_, attrs, inner] -> {cell_col(attrs), cell_value(attrs, inner, shared)} end)
    |> Enum.sort_by(fn {col, _} -> col end)
    |> Enum.map(fn {_, val} -> val end)
  end

  defp cell_col(attrs) do
    case Regex.run(~r{r="([A-Z]+)\d+"}, attrs) do
      [_, letters] -> col_index(letters)
      _ -> 0
    end
  end

  defp col_index(letters) do
    letters
    |> String.to_charlist()
    |> Enum.reduce(0, fn ch, acc -> acc * 26 + (ch - ?A + 1) end)
  end

  defp cell_value(attrs, inner, shared) do
    raw =
      case Regex.run(~r{<v>(.*?)</v>}s, inner) do
        [_, v] ->
          v

        _ ->
          case Regex.run(~r{<t[^>]*>(.*?)</t>}s, inner),
            do: (
              [_, t] -> t
              _ -> ""
            )
      end

    if shared_cell?(attrs) do
      Enum.at(shared, String.to_integer(String.trim(raw)), "")
    else
      decode_entities(raw)
    end
  rescue
    _ -> ""
  end

  defp shared_cell?(attrs), do: Regex.match?(~r{t="s"}, attrs)

  # --- shared helpers ---

  defp rows_to_markdown([]), do: ""

  defp rows_to_markdown(rows) do
    width = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if width == 0 do
      ""
    else
      [header | body] = Enum.map(rows, &pad_row(&1, width))
      sep = List.duplicate("---", width)

      [header, sep | body]
      |> Enum.map_join("\n", fn cells -> "| " <> Enum.join(cells, " | ") <> " |" end)
    end
  end

  defp pad_row(cells, width) do
    cells = Enum.map(cells, &String.replace(&1, "|", "\\|"))
    cells ++ List.duplicate("", width - length(cells))
  end

  defp from_zip(path, entry, parse_fn) do
    case unzip_all(path) do
      {:ok, files} ->
        case Map.get(files, entry) do
          nil -> {:error, "#{Path.extname(path)} archive missing #{entry}"}
          bin -> {:ok, parse_fn.(bin)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unzip_all(path) do
    charlist = String.to_charlist(path)

    with :ok <- check_archive_size(charlist),
         {:ok, entries} <- :zip.unzip(charlist, [:memory]) do
      {:ok, Map.new(entries, fn {n, b} -> {List.to_string(n), b} end)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "could not read archive: #{inspect(reason)}"}
    end
  end

  # Reject the archive before decompressing if its entries claim a combined
  # uncompressed size over the cap — a zip bomb can be a tiny file on disk.
  defp check_archive_size(charlist) do
    case :zip.list_dir(charlist) do
      {:ok, entries} ->
        total =
          Enum.reduce(entries, 0, fn
            {:zip_file, _name, info, _comment, _offset, _comp}, acc ->
              acc + entry_size(info)

            _other, acc ->
              acc
          end)

        if total > @max_unzip_bytes,
          do: {:error, "archive is too large when decompressed"},
          else: :ok

      {:error, reason} ->
        {:error, "could not read archive: #{inspect(reason)}"}
    end
  end

  # Uncompressed byte size from a :zip.list_dir file_info record (size is the 2nd
  # element). Defensive: any unexpected shape contributes 0.
  defp entry_size(info) when is_tuple(info) and tuple_size(info) > 1 do
    case elem(info, 1) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  defp entry_size(_), do: 0

  defp strip_tags(s), do: String.replace(s, ~r{<[^>]*>}, "")

  defp decode_entities(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
