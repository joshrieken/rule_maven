defmodule RuleMaven.RulebookDownloader do
  @moduledoc """
  Downloads PDF rulebooks from URLs, extracts text via pdftotext,
  and creates rulebook source records. Also searches for rulebooks
  using LLM knowledge and BGG.
  """

  alias RuleMaven.Games

  @bgg_base "https://boardgamegeek.com"
  @pdf_link_re ~r{<a[^>]*href="([^"]*\.pdf)"[^>]*>(.*?)</a>}s

  # Hard caps so a download can never hang the Oban job indefinitely.
  @max_pdf_bytes 80 * 1024 * 1024
  @fetch_connect_timeout 15_000
  @fetch_receive_timeout 60_000
  @pdftotext_timeout 90_000
  @pdftoppm_timeout 180_000
  @tesseract_timeout 90_000

  # Page-image render resolution for both vision transcription and OCR. 300 dpi
  # grayscale resolves small/decorative glyphs without bloating image-token cost.
  @render_dpi 300
  # Max concurrent vision calls (remote LLM, not local CPU) when transcribing a
  # book page-by-page.
  @vision_concurrency 4

  # No-op progress sink used when a caller doesn't care about stage updates.
  defp noop_progress(_stage), do: :ok

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
  def find_and_download(game, label \\ "", on_progress \\ &noop_progress/1) do
    on_progress.(:searching)

    case find_url_via_llm(game) do
      {:ok, url} ->
        try_download(game, url, label, on_progress)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_download(game, url, label, on_progress) do
    label = if label == "", do: extract_filename_label(url), else: label
    require Logger

    Logger.debug("Attempting download: #{url}")

    case download(game, url, label, on_progress) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "#{reason} (URL: #{url})"}
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
  def download(game, url, label, on_progress \\ &noop_progress/1) do
    label = if label == "", do: extract_filename_label(url), else: label
    on_progress.(:fetching)

    with {:ok, pdf_binary} <- fetch_pdf(url),
         :ok <- validate_pdf(pdf_binary),
         {:ok, pdf_path} <- save_pdf(pdf_binary, url) do
      ingest_saved_pdf(game, pdf_path, url, label, on_progress)
    end
  end

  @doc """
  Ingests an already-saved local PDF (e.g. a user upload copied into the uploads
  dir) for a game: extracts text (OCR-with-timeout for scanned PDFs), numbers
  pages, and creates the rulebook source. `pdf_path` is the static-relative path
  under priv/static. Returns `{:ok, source}` or `{:error, reason}`.

  This is the same extraction pipeline as `download/4` minus the network fetch,
  so uploads get the identical durable/timeout-guarded handling.
  """
  def ingest_local(game, pdf_path, label \\ "", on_progress \\ &noop_progress/1) do
    label = if label == "", do: extract_filename_label(pdf_path), else: label
    ingest_saved_pdf(game, pdf_path, nil, label, on_progress)
  end

  # Shared post-save tail of both download and upload ingestion.
  defp ingest_saved_pdf(game, pdf_path, url, label, on_progress) do
    with {:ok, raw_text, from_ocr} <- extract_with_cleanup(pdf_path, on_progress) do
      on_progress.(:finalizing)
      # Number pages (printed page when detectable, else physical sheet) so the
      # reader can distinguish them.
      pages = String.split(raw_text, "\f")
      page_structs = Games.paginate(pages)
      text = Games.rebuild_full_text(page_structs)
      html_path = text_to_html(text, pdf_path)
      full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

      Games.create_rulebook_source(%{
        game_id: game.id,
        label: label,
        pages: page_structs,
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

  @doc """
  Renders the marker-delimited rulebook `text` into a readable HTML file next to
  the PDF (same basename, `.html`). Returns the static-relative html_path, or nil
  on failure. Used at ingest and re-run after cleanup so the HTML reflects the
  current (cleaned) text.
  """
  def text_to_html(text, pdf_path) do
    html_filename = Path.basename(pdf_path, Path.extname(pdf_path)) <> ".html"
    html_path = Path.join(Path.dirname(pdf_path), html_filename)
    dest = Application.app_dir(:rule_maven, "priv/static/#{html_path}")

    pages = String.split(text, "\f")

    {paragraphs, _para_num} =
      pages
      |> Enum.reduce({[], 1}, fn page_chunk, {acc, para_num} ->
        # The chunk's marker ("===== SHEET 1 PAGE 1 =====") carries the real page
        # label. Use it for the divider, then strip it from the body so the raw
        # sigil doesn't show. (Positional indexing was off-by-one because the
        # text starts with a leading \f → empty first chunk.)
        {label, body} = page_label_and_body(page_chunk)
        body = String.trim(body)

        if body == "" do
          {acc, para_num}
        else
          page_paras =
            body
            |> String.split(~r{\n\s*\n})
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          divider = "<div class=\"page-break\">— #{label} —</div>"

          {page_acc, next_para} =
            Enum.reduce(page_paras, {[divider | acc], para_num}, fn para, {list, pn} ->
              para_html =
                "<p id=\"p#{pn}\" data-page=\"#{label}\">#{String.replace(para, "\n", "<br>")}</p>"

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

  # Splits a "\f"-delimited page chunk into its display label and body. Reads the
  # marker ("===== SHEET 3 PAGE 3 =====" → "Page 3"; "===== SHEET 4 =====" →
  # "Sheet 4") and strips it; falls back to "Page" with no number if absent.
  defp page_label_and_body(chunk) do
    case Regex.run(~r/=====\s*SHEET\s+(\d+)(?:\s+PAGE\s+(\d+))?\s*=====/, chunk) do
      [marker, _sheet, printed] when printed != "" ->
        {"Page #{printed}", String.replace(chunk, marker, "")}

      [marker, sheet | _] ->
        {"Sheet #{sheet}", String.replace(chunk, marker, "")}

      _ ->
        {"Page", chunk}
    end
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
    opts = [
      max_retries: 1,
      connect_options: [timeout: @fetch_connect_timeout],
      receive_timeout: @fetch_receive_timeout,
      redirect: true,
      max_redirects: 5,
      headers: add_browser_headers([])
    ]

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} ->
        body = if is_binary(body), do: body, else: IO.iodata_to_binary(body)

        cond do
          byte_size(body) == 0 ->
            {:error, "Server returned an empty response"}

          byte_size(body) > @max_pdf_bytes ->
            {:error, "PDF is too large (> #{div(@max_pdf_bytes, 1024 * 1024)} MB)"}

          true ->
            {:ok, body}
        end

      {:ok, %{status: status}} when status in 300..399 ->
        {:error, "Server kept redirecting (status #{status}) — link may be broken"}

      {:ok, %{status: 404}} ->
        {:error, "Rulebook not found at that URL (404)"}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, "Access denied by the server (status #{status}) — may require login"}

      {:ok, %{status: status}} ->
        {:error, "Server returned status #{status}"}

      {:error, %{reason: :timeout}} ->
        {:error, "Download timed out — URL may be unreachable or too slow"}

      {:error, %{reason: reason}} ->
        {:error, "Download failed: #{reason}"}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  # Guard against servers that answer 200 with an HTML error/login page (or any
  # non-PDF body): bail before we save garbage and waste time OCR-thrashing it.
  defp validate_pdf(binary) do
    head = binary |> binary_part(0, min(byte_size(binary), 1024)) |> String.trim_leading()

    cond do
      String.starts_with?(head, "%PDF-") ->
        :ok

      String.starts_with?(head, "<") or
          String.match?(String.downcase(head), ~r/<!doctype html|<html/) ->
        {:error, "That URL returned a web page, not a PDF file"}

      true ->
        {:error, "Downloaded file is not a valid PDF"}
    end
  end

  # Runs an external command with a hard timeout so a wedged binary (a corrupt
  # PDF that hangs pdftotext, a stuck tesseract) can't pin the Oban job forever.
  defp cmd(bin, args, timeout, opts \\ []) do
    task = Task.async(fn -> System.cmd(bin, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end

  # Extract, but if extraction fails for good, remove the PDF we just saved —
  # no Document row will reference it, so it would otherwise linger on disk.
  defp extract_with_cleanup(pdf_path, on_progress) do
    case extract_text_with_source(pdf_path, on_progress) do
      {:ok, _text, _from_ocr} = ok ->
        ok

      {:error, _reason} = err ->
        Application.app_dir(:rule_maven, "priv/static/#{pdf_path}") |> File.rm()
        err
    end
  end

  defp extract_text_with_source(pdf_path, on_progress) do
    full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    case extract_mode() do
      "vision" ->
        case vision_first_extract(full_path, on_progress) do
          {:ok, _text, _from_ocr} = ok ->
            ok

          {:error, reason} ->
            require Logger

            Logger.info(
              "Vision-first extraction unavailable (#{inspect(reason)}); using OCR path"
            )

            legacy_extract(full_path, on_progress)
        end

      _ ->
        legacy_extract(full_path, on_progress)
    end
  rescue
    e ->
      {:error, "PDF extraction error: #{Exception.message(e)}"}
  end

  # Extraction mode: "vision" renders every page and transcribes it with the
  # vision model — highest accuracy on graphic-heavy, multi-column, hard-to-read
  # rulebooks. "ocr" uses pdftotext with OCR + vision fallback only on junk pages
  # (cheaper). Defaults to vision.
  defp extract_mode do
    case RuleMaven.Settings.get("rulebook_extract_mode") do
      m when m in ["vision", "ocr"] -> m
      _ -> "vision"
    end
  end

  # Original path: trust a good text layer, else OCR. Used as the fallback when
  # vision-first can't run (no renderer / vision unavailable) and as the "ocr"
  # mode itself.
  defp legacy_extract(full_path, on_progress) do
    on_progress.(:extracting)

    case cmd("pdftotext", [full_path, "-"], @pdftotext_timeout) do
      {:ok, {text, 0}} ->
        if String.trim(text) != "" do
          {:ok, text, false}
        else
          run_ocr(full_path, on_progress)
        end

      {:ok, _nonzero} ->
        run_ocr(full_path, on_progress)

      {:error, :timeout} ->
        {:error, "PDF text extraction timed out — the file may be corrupt or too complex"}
    end
  end

  # Vision-first: render each sheet to an image and transcribe it to Markdown via
  # the vision model, preserving sheet order (so downstream pagination/printed-page
  # detection works unchanged). Each page is read by the default vision model; a
  # page that comes back empty/garbled is re-read by the escalation model. Joins
  # pages with "\f" exactly like the OCR path, so the marker/paginate pipeline is
  # untouched. Returns {:ok, text, true} (true = not from a native text layer).
  defp vision_first_extract(full_path, on_progress) do
    if System.find_executable("pdftoppm") do
      on_progress.(:extracting)

      case render_pages(full_path) do
        {:ok, []} ->
          {:error, "PDF produced no pages to transcribe"}

        {:ok, images} ->
          on_progress.(:ocr)

          text =
            images
            |> Task.async_stream(&vision_page/1,
              max_concurrency: @vision_concurrency,
              ordered: true,
              timeout: :infinity
            )
            |> Enum.map(fn
              {:ok, t} -> t
              _ -> ""
            end)
            |> Enum.join("\f")

          Enum.each(images, &File.rm/1)

          if String.trim(text) == "" do
            {:error, "Vision extraction produced no readable text"}
          else
            {:ok, text, true}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_renderer}
    end
  end

  # Transcribe one page image with the default vision model; if it comes back
  # empty or garbled (the escalation trigger), re-read with the stronger/higher-res
  # escalation model and keep whichever output is richer. "" on total failure.
  defp vision_page(image_path) do
    case RuleMaven.LLM.transcribe_page_image(image_path) do
      {:ok, text} ->
        if ocr_junk?(text), do: escalate_page(image_path, text), else: text

      {:error, _reason} ->
        escalate_page(image_path, "")
    end
  end

  # Re-read a page with the escalation vision model; keep the longer of the new
  # and fallback texts (never replace usable text with nothing).
  defp escalate_page(image_path, fallback) do
    opts = [model: RuleMaven.LLM.vision_model(:escalate), max_tokens: 8192]

    case RuleMaven.LLM.transcribe_page_image(image_path, opts) do
      {:ok, text} ->
        if String.length(String.trim(text)) >= String.length(String.trim(fallback)),
          do: text,
          else: fallback

      {:error, _reason} ->
        fallback
    end
  end

  # Renders each PDF sheet to a grayscale PNG at @render_dpi under tmp/ocr,
  # returning {:ok, sorted_image_paths}. Caller deletes the images. Shared by the
  # vision and OCR paths so both get identical page rendering.
  defp render_pages(pdf_path) do
    tmp_dir = Application.app_dir(:rule_maven, "tmp/ocr")
    File.mkdir_p!(tmp_dir)
    prefix = Path.join(tmp_dir, "#{System.system_time(:millisecond)}_page")

    case cmd(
           "pdftoppm",
           ["-png", "-gray", "-r", to_string(@render_dpi), pdf_path, prefix],
           @pdftoppm_timeout
         ) do
      {:ok, {_, 0}} ->
        images =
          tmp_dir
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
          |> Enum.sort()
          |> Enum.map(&Path.join(tmp_dir, &1))

        {:ok, images}

      {:ok, {_, _}} ->
        {:error, "pdftoppm failed — cannot convert PDF to images"}

      {:error, :timeout} ->
        {:error, "PDF→image conversion timed out — the file is too large or complex"}
    end
  end

  defp run_ocr(full_path, on_progress) do
    on_progress.(:ocr)

    case ocr_text(full_path) do
      {:ok, text} -> {:ok, text, true}
      {:error, reason} -> {:error, reason}
    end
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
      case render_pages(pdf_path) do
        {:ok, []} ->
          {:error, "OCR produced no text — PDF may be image-based with no readable content"}

        {:ok, images} ->
          # OCR pages in parallel across cores (tesseract is single-threaded per
          # invocation), preserving page order. Cuts an N-page scan from N×t to
          # roughly N/cores × t.
          ocr_pages =
            images
            |> Task.async_stream(
              fn img ->
                case cmd(
                       "tesseract",
                       [img, "stdout", "-l", "eng", "--psm", "6"],
                       @tesseract_timeout, stderr_to_stdout: true) do
                  {:ok, {t, _}} -> t
                  {:error, :timeout} -> ""
                end
              end,
              max_concurrency: System.schedulers_online(),
              ordered: true,
              timeout: :infinity
            )
            |> Enum.map(fn
              {:ok, t} -> t
              _ -> ""
            end)

          # Vision fallback for the pages OCR mangled (heavy graphics / overlaid
          # decorative text) or couldn't read at all. Only the bad pages hit the
          # vision model, so cost stays bounded. On any failure we keep the OCR
          # text. Capped concurrency: these are remote LLM calls, not local CPU.
          text =
            Enum.zip(images, ocr_pages)
            |> Task.async_stream(
              fn {img, ocr} ->
                if ocr_junk?(ocr), do: vision_or_ocr(img, ocr), else: ocr
              end,
              max_concurrency: @vision_concurrency,
              ordered: true,
              timeout: :infinity
            )
            |> Enum.map(fn
              {:ok, t} -> t
              _ -> ""
            end)
            |> Enum.join("\f")

          # Cleanup temp images
          Enum.each(images, &File.rm/1)

          if String.trim(text) == "" do
            {:error, "OCR produced no text — PDF may be image-based with no readable content"}
          else
            {:ok, text}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "PDF has no text layer. Install tesseract for OCR: brew install tesseract"}
    end
  end

  # Re-transcribe one page image with the vision model, falling back to the OCR
  # text if vision fails or comes back empty (never replace usable OCR with
  # nothing).
  defp vision_or_ocr(image_path, ocr_text) do
    case RuleMaven.LLM.transcribe_page_image(image_path) do
      {:ok, text} ->
        if String.trim(text) == "", do: ocr_text, else: text

      {:error, reason} ->
        require Logger
        Logger.warning("Vision OCR fallback failed for #{image_path}: #{inspect(reason)}")
        ocr_text
    end
  end

  @doc """
  Heuristic: does this page's OCR output look like garbage (so a vision re-read
  is worth the LLM call)? True when the page is empty (image-only page tesseract
  couldn't read) or when fewer than half its tokens are real words — the
  signature of graphic/decorative pages OCR scrambles into symbol soup.
  """
  def ocr_junk?(text) do
    tokens = String.split(text || "", ~r/\s+/, trim: true)

    case length(tokens) do
      0 ->
        true

      total ->
        wordish = Enum.count(tokens, &wordish_token?/1)
        wordish / total < 0.5
    end
  end

  # A "real word": starts with a letter, 3+ letters long, and contains a vowel.
  # Rejects single chars, symbol fragments ("e¢", "®"), and OCR consonant soup
  # ("YopM&y", "BOARO" passes — fine, it's recoverable; "frg" / "ttt" don't).
  defp wordish_token?(tok) do
    Regex.match?(~r/^[A-Za-z][A-Za-z'’-]{2,}$/u, tok) and Regex.match?(~r/[aeiouAEIOUyY]/, tok)
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
