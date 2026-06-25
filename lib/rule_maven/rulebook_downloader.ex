defmodule RuleMaven.RulebookDownloader do
  @moduledoc """
  Downloads PDF rulebooks from URLs, extracts text via pdftotext,
  and creates rulebook source records. Also searches for rulebooks
  using LLM knowledge and BGG.
  """

  alias RuleMaven.Games

  @bgg_base "https://boardgamegeek.com"
  @pdf_link_re ~r{<a[^>]*href="([^"]*\.pdf)"[^>]*>(.*?)</a>}s

  @doc """
  Uses the LLM to find a PDF rulebook URL for a game.
  Returns `{:ok, url}` or `{:error, reason}`.
  """
  def find_url_via_llm(game) do
    require Logger

    prompt = """
    Official PDF rulebook URL for "#{game.name}"? Return only URL. No guess — UNKNOWN if unsure.
    """

    case RuleMaven.LLM.chat(prompt, "rulebook url search") do
      {:ok, text} ->
        Logger.debug("LLM rulebook search raw: #{String.slice(text, 0, 300)}")
        text = String.trim(text)

        if text == "" or String.contains?(text, "UNKNOWN") do
          {:error, "No known rulebook URL for #{game.name}"}
        else
          case Regex.run(~r{https?://[^\s"'<>]+}i, text) do
            [url | _] ->
              url = String.trim(url, "\"'.,;)")
              Logger.debug("LLM returned URL: #{url}")
              {:ok, url}

            _ ->
              {:error, "No URL found in LLM response"}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Finds a rulebook URL (tries LLM) and downloads it.
  Tries multiple URLs if the LLM returns several.
  Returns `{:ok, source}` or `{:error, reason}`.
  """
  def find_and_download(game, label \\ "") do
    case find_url_via_llm(game) do
      {:ok, url} ->
        try_download(game, url, label)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_download(game, url, label) do
    label = if label == "", do: extract_filename_label(url), else: label
    require Logger

    Logger.debug("Attempting download: #{url}")

    case download(game, url, label) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "#{inspect(reason)} (URL: #{url})"}
    end
  end

  @doc """
  Searches BGG files page for PDF rulebooks. Returns a list of
  `%{url: url, label: name}` entries. Pass optional cookies for
  private file access.
  """
  def find_on_bgg(bgg_id, opts \\ []) do
    cookies = Keyword.get(opts, :cookies)
    url = "#{@bgg_base}/boardgame/#{bgg_id}/files?pageid=1&languageid=2184"
    headers = build_headers(cookies) |> add_browser_headers()

    require Logger
    Logger.debug("Fetching BGG files page: #{url}")

    case Req.get(url, headers: headers, max_retries: 1) do
      {:ok, %{status: 200, body: html}} ->
        Logger.debug("BGG files page fetched: #{byte_size(html)} bytes")
        links = parse_pdf_links(html)
        Logger.debug("Found #{length(links)} PDF links")
        {:ok, links}

      {:ok, %{status: status}} ->
        {:error, "BGG files page returned status #{status}"}

      {:error, reason} ->
        {:error, "Failed to fetch BGG files: #{inspect(reason)}"}
    end
  end

  @doc """
  Downloads a PDF from a URL, saves to uploads dir, extracts text,
  and creates a rulebook source for the given game.
  Returns `{:ok, source}` or `{:error, reason}`.
  """
  def download(game, url, label) do
    label = if label == "", do: extract_filename_label(url), else: label

    with {:ok, pdf_binary} <- fetch_pdf(url),
         {:ok, pdf_path} <- save_pdf(pdf_binary, url),
         {:ok, raw_text, from_ocr} <- extract_text_with_source(pdf_path) do
      # Number pages (printed page when detectable, else physical sheet) so the
      # reader can distinguish them — same treatment as the upload path.
      pages = String.split(raw_text, "\f")
      text = Games.number_pages(pages)
      html_path = text_to_html(text, pdf_path)
      full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

      Games.create_rulebook_source(%{
        game_id: game.id,
        label: label,
        full_text: text,
        pdf_path: pdf_path,
        html_path: html_path,
        source_url: url,
        content_type: "application/pdf",
        file_size: file_size(full_path),
        page_count: length(pages),
        printed_offset: Games.detect_printed_offset(pages),
        from_ocr: from_ocr,
        extracted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp text_to_html(text, pdf_path) do
    html_filename = Path.basename(pdf_path, Path.extname(pdf_path)) <> ".html"
    html_path = Path.join(Path.dirname(pdf_path), html_filename)
    dest = Application.app_dir(:rule_maven, "priv/static/#{html_path}")

    pages = String.split(text, "\f")

    {paragraphs, _para_num} =
      pages
      |> Enum.with_index(1)
      |> Enum.reduce({[], 1}, fn {page_text, page_num}, {acc, para_num} ->
        page_text = String.trim(page_text)

        if page_text == "" do
          {acc, para_num}
        else
          page_paras =
            page_text
            |> String.split(~r{\n\s*\n})
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          marker = "<div class=\"page-break\">— Page #{page_num} —</div>"

          {page_acc, next_para} =
            Enum.reduce(page_paras, {[marker | acc], para_num}, fn para, {list, pn} ->
              para_html =
                "<p id=\"p#{pn}\" data-page=\"#{page_num}\">#{String.replace(para, "\n", "<br>")}</p>"

              {[para_html | list], pn + 1}
            end)

          {page_acc, next_para}
        end
      end)

    paragraphs_html = paragraphs |> Enum.reverse() |> Enum.join("\n")

    html = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <style>
      body { font-family: Georgia, serif; font-size: 14px; line-height: 1.6; max-width: 720px; margin: 2rem auto; padding: 0 1rem; color: #222; }
      p { margin: 0.5rem 0; }
      p:hover { background: #fffde7; }
      .page-break { margin: 1.5rem 0 0.5rem 0; font-size: 12px; color: #999; border-top: 1px dashed #ccc; padding-top: 0.5rem; font-weight: 600; }
    </style></head>
    <body>
    #{paragraphs_html}
    </body></html>
    """

    File.write!(dest, html)
    html_path
  rescue
    _ -> nil
  end

  defp parse_pdf_links(html) do
    @pdf_link_re
    |> Regex.scan(html)
    |> Enum.map(fn [_, href, text] ->
      text = String.trim(text) |> strip_html() |> String.trim()
      url = normalize_url(String.trim(href))
      label = if text == "", do: extract_filename_label(url), else: text
      %{url: url, label: label}
    end)
    |> Enum.uniq_by(& &1.url)
    |> Enum.reject(fn %{label: l} -> l == "" end)
  end

  defp normalize_url("/" <> _ = path), do: @bgg_base <> path
  defp normalize_url(url), do: url

  defp strip_html(str) do
    String.replace(str, ~r/<[^>]*>/, "") |> String.trim()
  end

  defp build_headers(nil), do: []
  defp build_headers(cookies), do: [{"cookie", cookies}]

  defp add_browser_headers(headers) do
    [
      {"user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
      {"accept", "text/html,application/xhtml+xml"},
      {"accept-language", "en-US,en;q=0.9"}
      | headers
    ]
  end

  defp fetch_pdf(url) do
    case Req.get(url, max_retries: 0, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %{status: status}} ->
        {:error, "Server returned status #{status}"}

      {:error, %{reason: :timeout}} ->
        {:error, "Download timed out — URL may be unreachable or too slow"}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp extract_text_with_source(pdf_path) do
    full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    case System.cmd("pdftotext", [full_path, "-"]) do
      {text, 0} ->
        if String.trim(text) != "" do
          {:ok, text, false}
        else
          case ocr_text(full_path) do
            {:ok, text} -> {:ok, text, true}
            {:error, reason} -> {:error, reason}
          end
        end

      _ ->
        case ocr_text(full_path) do
          {:ok, text} -> {:ok, text, true}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      {:error, "PDF extraction error: #{Exception.message(e)}"}
  end

  defp save_pdf(pdf_binary, url) do
    upload_dir = Application.app_dir(:rule_maven, "priv/static/uploads/rulebooks")
    File.mkdir_p!(upload_dir)

    filename = "#{System.system_time(:millisecond)}_#{extract_filename(url)}"
    pdf_path = Path.join("uploads/rulebooks", filename)
    dest = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    case File.write(dest, pdf_binary) do
      :ok -> {:ok, pdf_path}
      {:error, reason} -> {:error, "Failed to save PDF: #{reason}"}
    end
  end

  defp ocr_text(pdf_path) do
    if System.find_executable("tesseract") do
      tmp_dir = Application.app_dir(:rule_maven, "tmp/ocr")
      File.mkdir_p!(tmp_dir)
      prefix = Path.join(tmp_dir, "#{System.system_time(:millisecond)}_page")

      case System.cmd("pdftoppm", ["-png", "-r", "300", pdf_path, prefix]) do
        {_, 0} ->
          images =
            tmp_dir
            |> File.ls!()
            |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
            |> Enum.sort()
            |> Enum.map(&Path.join(tmp_dir, &1))

          text =
            images
            |> Enum.map(fn img ->
              case System.cmd("tesseract", [img, "stdout", "-l", "eng", "--psm", "6"],
                     stderr_to_stdout: true
                   ) do
                {t, _} -> t
              end
            end)
            |> Enum.join("\f")

          # Cleanup temp images
          Enum.each(images, &File.rm/1)

          if String.trim(text) == "" do
            {:error, "OCR produced no text — PDF may be image-based with no readable content"}
          else
            {:ok, text}
          end

        {_, _} ->
          {:error, "pdftoppm failed — cannot convert PDF to images for OCR"}
      end
    else
      {:error, "PDF has no text layer. Install tesseract for OCR: brew install tesseract"}
    end
  end

  defp extract_filename(url) do
    uri = URI.parse(url)
    Path.basename(uri.path || "rulebook.pdf")
  end

  defp extract_filename_label(url) do
    url
    |> extract_filename()
    |> Path.rootname()
    |> String.replace(~r/[_\-]/, " ")
  end
end
