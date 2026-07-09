defmodule RuleMaven.RulebookDownloader do
  @moduledoc """
  Downloads PDF rulebooks from URLs, extracts text via pdftotext,
  and creates rulebook source records. Also searches for rulebooks
  using LLM knowledge and BGG.
  """

  alias RuleMaven.Games
  alias RuleMaven.Games.Document
  alias RuleMaven.Extract.{Calibrate, Critic, Gate, Native}

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
  # A manual single-page re-extract is the user asking for a *better* read after
  # the page already escalated at @render_dpi. Re-running the same image + same
  # model just reproduces the same text, so re-extract renders sharper (higher
  # dpi) to actually give the strong model something new to work with.
  @reextract_dpi 450
  # Mid escalation tier (T2) re-renders the page sharper than @render_dpi so a
  # re-read has something new to see — same value as a manual re-extract.
  @t2_dpi 450
  # Two of N reads agreeing at/above this (token-set Jaccard) settles a T2 page
  # without paying for the critic. Matches the gate's cross-check agree threshold.
  @t2_majority 0.75
  # Max concurrent vision calls (remote LLM, not local CPU) when transcribing a
  # book page-by-page.
  @vision_concurrency 8

  # Page images go to the model as grayscale JPEG: providers downscale/tile the
  # image to the same token count regardless of encoding, so JPEG only shrinks
  # the base64 upload (~2-5x vs PNG, measured 1.8x on a dense page) — faster,
  # same accuracy. Quality 90 keeps compression artifacts below what
  # tesseract/vision notice.
  @jpeg_args ["-jpeg", "-jpegopt", "quality=90", "-gray"]

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
      save_source(game, pdf_path, url, label, on_progress)
    end
  end

  @doc """
  Ingests an already-saved local PDF (e.g. a user upload copied into the uploads
  dir) for a game: extracts text (OCR-with-timeout for scanned PDFs), numbers
  pages, and creates the rulebook source. `pdf_path` is the static-relative path
  under priv/static. Returns `{:ok, source}` or `{:error, reason}`.

  Extraction is deferred: this saves the source only. Fill its page text later
  with `extract_document/2` (run by `ExtractWorker` from the prepare page).
  """
  def ingest_local(game, pdf_path, label \\ "", on_progress \\ &noop_progress/1) do
    label = if label == "", do: extract_filename_label(pdf_path), else: label
    save_source(game, pdf_path, nil, label, on_progress)
  end

  @doc """
  Persist a rulebook source from an already-saved file WITHOUT extracting its
  text. Creates a `Document` with `pages: []` (unextracted) plus the file
  metadata + content hash. Extraction runs later via `extract_document/2`.
  """
  def save_source(game, pdf_path, url, label, on_progress \\ &noop_progress/1) do
    on_progress.(:finalizing)
    full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}")

    Games.create_rulebook_source(%{
      game_id: game.id,
      label: label,
      pages: [],
      full_text: nil,
      pdf_path: pdf_path,
      source_url: url,
      content_type: content_type_for(pdf_path),
      file_size: file_size(full_path),
      file_hash: file_hash(full_path)
    })
  end

  @doc """
  Extract a saved source's text and fill its pages. Runs the same
  timeout-guarded vision/OCR pipeline as before, then `update_document` (which
  rebuilds the HTML view and invalidates stale cached answers). Chunking is
  deliberately skipped (`chunk: false`) — embedding is its own pipeline step
  and must not run (or read as done) before the text is cleaned.
  Returns `{:ok, document}` or `{:error, reason}`.
  """
  def extract_document(doc, on_progress \\ &noop_progress/1)

  def extract_document(%Document{pdf_path: pdf_path} = doc, on_progress)
      when is_binary(pdf_path) and pdf_path != "" do
    with {:ok, raw_text, from_ocr, page_meta} <-
           extract_with_cleanup(pdf_path, on_progress, doc.game_id) do
      on_progress.(:finalizing)
      # Number pages (printed page when detectable, else physical sheet) so the
      # reader can distinguish them.
      pages = String.split(raw_text, "\f")
      page_structs = Games.paginate(pages) |> attach_page_meta(page_meta)
      text = Games.rebuild_full_text(page_structs)

      Games.update_document(
        doc,
        %{
          pages: page_structs,
          full_text: text,
          content_type: content_type_for(pdf_path),
          page_count: length(pages),
          printed_offset: Games.detect_printed_offset(pages),
          from_ocr: from_ocr,
          extracted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        chunk: false
      )
    end
  end

  def extract_document(%Document{}, _on_progress), do: {:error, "no source file to extract"}

  # Merges per-page extraction provenance (confidence/lane/source from the gate)
  # onto the paginated page structs. `meta` is physical-order, aligned 1:1 with
  # the "\f"-split pages. nil (legacy/OCR path) leaves pages unchanged. Any pages
  # beyond the meta list (shouldn't happen) keep their bare struct.
  defp attach_page_meta(pages, nil), do: pages

  defp attach_page_meta(pages, meta) do
    merged =
      Enum.zip(pages, meta)
      |> Enum.map(fn {p, m} ->
        Map.merge(p, %{
          confidence: m.confidence,
          lane: m.lane,
          source: m.source,
          # Decision-log detail (nil for keys a given lane didn't produce).
          gate_agreement: Map.get(m, :gate_agreement),
          gate_coverage: Map.get(m, :gate_coverage),
          escalated: Map.get(m, :escalated),
          critic_rounds: Map.get(m, :critic_rounds),
          residual_defects: Map.get(m, :residual_defects)
        })
      end)

    merged ++ Enum.drop(pages, length(merged))
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  # SHA-256 of the stored file, used to dedup an identical re-ingest (a retried
  # download attempt saves the PDF under a fresh timestamped name, so the path
  # differs but the bytes don't). nil when the file can't be read.
  defp file_hash(path) do
    case File.read(path) do
      {:ok, bin} -> :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  # MIME type from the stored file's extension, for the Document.content_type
  # field. Defaults to application/pdf (the historical assumption and URL-download
  # case).
  defp content_type_for(path) do
    case Path.extname(path) |> String.downcase() do
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".odt" -> "application/vnd.oasis.opendocument.text"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".csv" -> "text/csv"
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".markdown" -> "text/markdown"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "application/pdf"
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

    html = render_html_doc(paragraphs_html)

    File.write!(dest, html)
    html_path
  rescue
    _ -> nil
  end

  # Wraps the rendered paragraphs in a self-contained, themeable HTML document.
  # Light/dark are pure CSS variables; the inline <head> script applies the
  # saved choice (localStorage key "rulebook-theme") before first paint to avoid
  # a flash, falling back to the OS `prefers-color-scheme` when no choice is
  # stored. The toggle button writes the choice back. No external assets, so the
  # file stays viewable standalone.
  defp render_html_doc(paragraphs_html) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script>
      (function () {
        try {
          var saved = localStorage.getItem("rulebook-theme");
          if (saved === "light" || saved === "dark") {
            document.documentElement.setAttribute("data-theme", saved);
          }
        } catch (e) {}
      })();
    </script>
    <style>
      :root {
        --bg: #ffffff;
        --text: #222222;
        --muted: #999999;
        --rule: #cccccc;
        --highlight: #fffde7;
        --btn-bg: #f4f4f4;
        --btn-border: #d0d0d0;
        color-scheme: light;
      }
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) {
          --bg: #1a1a1e;
          --text: #d8d4cc;
          --muted: #777777;
          --rule: #3a3a40;
          --highlight: #2e2c20;
          --btn-bg: #26262c;
          --btn-border: #3a3a42;
          color-scheme: dark;
        }
      }
      [data-theme="dark"] {
        --bg: #1a1a1e;
        --text: #d8d4cc;
        --muted: #777777;
        --rule: #3a3a40;
        --highlight: #2e2c20;
        --btn-bg: #26262c;
        --btn-border: #3a3a42;
        color-scheme: dark;
      }
      html, body { background: var(--bg); }
      body {
        font-family: Georgia, serif;
        font-size: 14px;
        line-height: 1.6;
        max-width: 720px;
        margin: 2rem auto;
        padding: 0 1rem 4rem;
        color: var(--text);
        transition: background 0.2s ease, color 0.2s ease;
      }
      p { margin: 0.5rem 0; }
      p:hover { background: var(--highlight); }
      .page-break {
        margin: 1.5rem 0 0.5rem 0;
        font-size: 12px;
        color: var(--muted);
        border-top: 1px dashed var(--rule);
        padding-top: 0.5rem;
        font-weight: 600;
      }
      .theme-toggle {
        position: fixed;
        top: 0.75rem;
        right: 0.75rem;
        font: 600 12px/1 system-ui, sans-serif;
        background: var(--btn-bg);
        color: var(--text);
        border: 1px solid var(--btn-border);
        border-radius: 999px;
        padding: 0.4rem 0.7rem;
        cursor: pointer;
        z-index: 10;
        opacity: 0.85;
        transition: opacity 0.15s ease;
      }
      .theme-toggle:hover { opacity: 1; }
      @media print { .theme-toggle { display: none; } }
    </style>
    </head>
    <body>
    <button type="button" class="theme-toggle" aria-label="Toggle light or dark theme" onclick="__rmToggleTheme()">◐ Theme</button>
    <script>
      function __rmToggleTheme() {
        var el = document.documentElement;
        var current = el.getAttribute("data-theme");
        if (!current) {
          var prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
          current = prefersDark ? "dark" : "light";
        }
        var next = current === "dark" ? "light" : "dark";
        el.setAttribute("data-theme", next);
        try { localStorage.setItem("rulebook-theme", next); } catch (e) {}
      }
    </script>
    #{paragraphs_html}
    </body>
    </html>
    """
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

  # The source PDF is NEVER deleted on an extraction failure.
  #
  # This used to `File.rm` the file, on the premise (stated in its old comment)
  # that "no Document row will reference it." That premise is false: the only
  # caller is `extract_document/2`, which is handed an existing `%Document{}`
  # whose `pdf_path` is this file. And extraction fails for transient reasons —
  # a pdftotext/pdftoppm timeout, an LLM outage making every page come back
  # empty, a momentary :no_renderer. `ExtractWorker` deliberately returns :ok on
  # failure so an admin can re-run it, but the re-run was doomed: the source was
  # already gone, irrecoverably, from one bad rate-limit window.
  #
  # Orphaned files from a failed *upload* are a disk-hygiene problem, not a
  # correctness one, and `delete_document/1` already removes the file on the
  # paths where a document really goes away.
  defp extract_with_cleanup(pdf_path, on_progress, game_id) do
    extract_text_with_source(pdf_path, on_progress, game_id)
  end

  defp extract_text_with_source(doc_path, on_progress, game_id) do
    full_path = Application.app_dir(:rule_maven, "priv/static/#{doc_path}")

    cond do
      Native.native?(doc_path) ->
        native_extract(full_path, on_progress)

      image?(doc_path) ->
        image_extract(full_path, on_progress, game_id)

      true ->
        pdf_extract(full_path, on_progress, game_id)
    end
  rescue
    e ->
      {:error, "Document extraction error: #{Exception.message(e)}"}
  end

  # Native-text formats (docx/odt/html/xlsx/csv/txt/md): structural parse, no OCR,
  # no model — the cheapest path to max accuracy. No per-page provenance (nil meta).
  defp native_extract(full_path, on_progress) do
    on_progress.(:extracting)
    log(on_progress, "Reading #{native_kind(full_path)} — text is exact, no OCR needed…")

    case Native.extract(full_path) do
      {:ok, text} ->
        if String.trim(text) == "" do
          {:error, "Document had no readable text"}
        else
          log(on_progress, "Extracted #{length(String.split(text, "\f"))} page(s)", :info)
          {:ok, text, false, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp native_kind(path) do
    case Path.extname(path) |> String.downcase() do
      e when e in ~w(.docx .odt) -> "Word document"
      e when e in ~w(.html .htm) -> "web page"
      e when e in ~w(.xlsx .csv) -> "spreadsheet"
      _ -> "text document"
    end
  end

  # A single uploaded image is one page with no text layer — run the same
  # per-page decision (local OCR vs vision, escalate on disagreement) the PDF
  # engine uses, with an empty layer.
  defp image_extract(full_path, on_progress, game_id) do
    on_progress.(:ocr)
    log(on_progress, "Reading image — OCR + vision cross-check…")
    # pdf_path nil: there is no PDF to re-render, so a T1 disagreement skips the
    # T2 sharper-render tier and goes straight to T3 (see escalate_tiers).
    r = decide_page(full_path, "", false, %{game_id: game_id, pdf_path: nil, page: 1})

    if String.trim(r.text) == "" do
      {:error, "Image produced no readable text"}
    else
      {:ok, r.text, true, [r]}
    end
  end

  # PDF: accuracy-first cross-check (mode "vision") or the legacy OCR path.
  defp pdf_extract(full_path, on_progress, game_id) do
    case extract_mode() do
      "vision" ->
        case crosscheck_extract(full_path, on_progress, game_id) do
          {:ok, _text, _from_ocr, _meta} = ok ->
            ok

          {:error, reason} ->
            require Logger
            Logger.info("Cross-check extraction unavailable (#{inspect(reason)}); using OCR path")
            legacy_extract(full_path, on_progress, game_id)
        end

      _ ->
        legacy_extract(full_path, on_progress, game_id)
    end
  end

  defp image?(path) do
    Path.extname(path) |> String.downcase() |> Kernel.in(~w(.png .jpg .jpeg .webp .gif))
  end

  # Extraction mode: "vision" runs the accuracy-first cross-check engine (trust a
  # clean text layer, else read two cheap ways and escalate disagreement). "ocr"
  # uses the original pdftotext + OCR + vision-fallback-on-junk path. Default vision.
  defp extract_mode do
    case RuleMaven.Settings.get("rulebook_extract_mode") do
      m when m in ["vision", "ocr"] -> m
      _ -> "vision"
    end
  end

  # Original path: trust a non-empty text layer, else OCR. Fallback when the
  # cross-check engine can't run (no renderer), and the "ocr" mode itself. Returns
  # a 4-tuple with nil page_meta (no per-page provenance from this path).
  defp legacy_extract(full_path, on_progress, game_id) do
    on_progress.(:extracting)

    case cmd("pdftotext", [full_path, "-"], @pdftotext_timeout) do
      {:ok, {text, 0}} ->
        if String.trim(text) != "" do
          {:ok, text, false, nil}
        else
          run_ocr(full_path, on_progress, game_id)
        end

      {:ok, _nonzero} ->
        run_ocr(full_path, on_progress, game_id)

      {:error, :timeout} ->
        {:error, "PDF text extraction timed out — the file may be corrupt or too complex"}
    end
  end

  # Accuracy-first cross-check engine. Per page: a clean text layer is trusted
  # as-is (no model call, no page render). Otherwise the page is rendered and
  # read two cheap, independent ways — text layer (or local OCR) and cheap
  # vision — and scored by the gate. Strong agreement is the accuracy ceiling,
  # so we stop; disagreement climbs the escalation ladder. Pages stay in
  # physical order and join with "\f", so the marker/paginate pipeline is
  # untouched. Returns {:ok, text, from_ocr, page_meta}.
  #
  # Rendering is lazy: pages are rendered one-by-one only when a page actually
  # needs an image (not T0-trusted, or drift-sampled). On a clean born-digital
  # book most pages skip pdftoppm entirely.
  defp crosscheck_extract(full_path, on_progress, game_id) do
    if System.find_executable("pdftoppm") do
      on_progress.(:extracting)

      case sheet_count(full_path) do
        {:ok, 0} ->
          {:error, "PDF produced no pages to extract"}

        {:ok, total} ->
          on_progress.(:ocr)

          log(
            on_progress,
            "Reading #{total} page(s) — trusting clean text, cross-checking the rest…"
          )

          # Positional layer↔sheet pairing is only safe when the text-layer page
          # count matches the sheet count. On any mismatch we discard the
          # layer entirely (every page cross-checks via OCR/vision) rather than
          # risk attaching a page's text to the wrong sheet — silent corruption is
          # the one thing accuracy-first must never do. A few extra vision calls
          # on a rare mismatch is the right trade.
          layer_pages = aligned_layers(pdftext_pages(full_path), total)

          # Read the drift-sample rate once for the whole book (avoids a Settings
          # DB read per page).
          drift_rate = Calibrate.drift_rate()

          results =
            1..total
            |> Task.async_stream(
              fn page ->
                layer = String.trim(Enum.at(layer_pages, page - 1) || "")
                ctx = %{game_id: game_id, pdf_path: full_path, page: page}
                r = decide_page_lazy(layer, drift_rate, ctx)
                log(on_progress, page_line(page, total, r), page_kind(r))
                r
              end,
              max_concurrency: @vision_concurrency,
              ordered: true,
              timeout: :infinity
            )
            |> Enum.map(fn
              {:ok, r} -> r
              _ -> %{text: "", confidence: 0.0, lane: "vision", source: "error"}
            end)

          text = results |> Enum.map(& &1.text) |> Enum.join("\f")

          if String.trim(text) == "" do
            {:error, "Extraction produced no readable text"}
          else
            # from_ocr: true unless every page came straight off the text layer.
            from_ocr = Enum.any?(results, &(&1.lane != "text_layer"))
            flagged = Enum.count(results, &(&1.source in ["critic_residual", "error"]))

            log(
              on_progress,
              "Read #{total} page(s) — #{total - flagged} clean, #{flagged} flagged for review",
              :info
            )

            {:ok, text, from_ocr, results}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_renderer}
    end
  end

  # Sheet count via pdfinfo (ships with poppler alongside pdftoppm/pdftotext).
  # Needed up front so lazy rendering can skip pdftoppm on trusted pages. On any
  # failure the caller errors out and pdf_extract falls back to the legacy path.
  defp sheet_count(full_path) do
    if System.find_executable("pdfinfo") do
      case cmd("pdfinfo", [full_path], @pdftotext_timeout) do
        {:ok, {out, 0}} ->
          case Regex.run(~r/^Pages:\s+(\d+)/m, out) do
            [_, n] -> {:ok, String.to_integer(n)}
            _ -> {:error, "could not read PDF page count"}
          end

        _ ->
          {:error, "pdfinfo failed — PDF may be corrupt"}
      end
    else
      {:error, :no_pdfinfo}
    end
  end

  # Returns the layer pages only if they align 1:1 with the rendered sheets
  # (after dropping trailing empty chunks pdftotext appends). On any count
  # mismatch returns [] so every page cross-checks instead of risking a
  # mis-paired sheet. `n` is the rendered image count.
  defp aligned_layers(layer_pages, n) do
    trimmed =
      layer_pages
      |> Enum.reverse()
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.reverse()

    if length(trimmed) == n, do: trimmed, else: []
  end

  # Whole-document text layer split into physical pages. NOTE: "-layout"
  # renders multi-column pages side by side — right words, wrong reading order.
  # Gate.column_suspect?/1 detects that shape; such pages skip the text layer
  # and are read from the image (OCR + vision) instead. Empty list on failure —
  # every page then falls through to OCR/vision.
  defp pdftext_pages(full_path) do
    case cmd("pdftotext", ["-layout", full_path, "-"], @pdftotext_timeout) do
      {:ok, {text, 0}} -> String.split(text, "\f")
      _ -> []
    end
  end

  # Lazy wrapper around the per-page decision: renders the sheet only when the
  # decision actually needs an image. A T0-trusted, non-sampled page returns
  # straight off the text layer with zero pdftoppm/model cost — on a clean
  # born-digital book that's most pages, and rendering was the wall-time floor.
  # The drift-sample draw happens here (before rendering) since it decides
  # whether a trusted page needs an image at all.
  defp decide_page_lazy(layer, drift_rate, ctx) do
    trusted? = Gate.clean_text_layer?(layer)
    sampled? = Calibrate.should_sample?(drift_rate)

    if trusted? and not sampled? do
      %{text: layer, confidence: 0.9, lane: "text_layer", source: "text_layer", escalated: false}
    else
      case render_one_page(ctx.pdf_path, ctx.page, @render_dpi) do
        {:ok, img} ->
          try do
            decide_page(img, layer, sampled?, ctx)
          after
            File.rm(img)
          end

        {:error, _} when trusted? ->
          # Drift sample that couldn't render — keep the trusted layer; the
          # sample is simply skipped (best-effort telemetry, never a cost).
          %{
            text: layer,
            confidence: 0.9,
            lane: "text_layer",
            source: "text_layer",
            escalated: false
          }

        {:error, _} ->
          # Un-renderable page with no trusted layer: keep whatever the layer
          # had rather than dropping the page, flagged for review.
          %{text: layer, confidence: 0.0, lane: "vision", source: "error"}
      end
    end
  end

  # The per-page decision — a cost-ordered validation ladder. Each rung is read
  # cheaply, validated by the cheapest check that can catch its failure, and only
  # climbs when that check is unsatisfied (recall-biased: unsure → climb):
  #
  #   T0  clean text layer → trust it, no model call ($0). A drift-sampled
  #       fraction cross-checks anyway to keep proving the layer is safe.
  #   T1  cross-check the layer (or OCR) against one cheap vision read; agreement
  #       (gate) settles it. Disagreement climbs.
  #   T2  higher-DPI re-read (same then mid model), settled by majority vote of
  #       the reads — no critic. See escalate_tiers/4.
  #   T3  top model + adversarial critic (escalate_page), the last resort.
  #
  # `sampled?` is the pre-drawn drift-sample decision (drawn before rendering,
  # in decide_page_lazy — a trusted page only renders when sampled).
  defp decide_page(image, layer, sampled?, ctx) do
    # A column-suspect layer (side-by-side columns from `pdftotext -layout`)
    # has the right words in the wrong order. Every signal downstream —
    # agreement, coverage, wordish, richer — is order-blind, so if the layer
    # stays in the candidate set it cross-checks clean against a vision read
    # and then WINS the richer() pick, storing the misordered text. Drop it
    # entirely: the page reads like a layerless one (OCR + vision, both from
    # the image, both in true reading order).
    layer = if Gate.column_suspect?(layer), do: "", else: String.trim(layer)

    if Gate.clean_text_layer?(layer) do
      # T0 drift sample (the only way a clean layer reaches here): cross-check +
      # strong-read it anyway and log the outcome, so we keep verifying that
      # "clean layer = safe" holds (the safety net that lets T0 trust on
      # structure alone).
      reader_b = vision_one(image, ctx.game_id)
      g = Gate.assess(layer, reader_b)

      escalate_page(image, richer(layer, reader_b),
        signals: g.signals,
        drift: true,
        game_id: ctx.game_id
      )
    else
      {reader_a, reader_b} = read_pair(image, layer, ctx.game_id)
      g = Gate.assess(reader_a, reader_b)
      text = richer(reader_a, reader_b)
      base_lane = if layer != "", do: "text_layer", else: "ocr"

      cond do
        # T1 agreed = accuracy ceiling. A small random sample escalates anyway and
        # logs the outcome, to keep verifying that "agreement = ceiling" holds
        # (drift detection). The sampled page keeps the escalated result.
        g.agree? and sampled? ->
          escalate_page(image, text, signals: g.signals, drift: true, game_id: ctx.game_id)

        g.agree? ->
          Map.merge(
            %{
              text: text,
              confidence: g.confidence,
              lane: base_lane,
              source: "crosscheck",
              escalated: false
            },
            gate_detail(g.signals)
          )

        # T1 disagreed → climb the mid ladder before the costly critic.
        true ->
          escalate_tiers(image, [reader_a, reader_b], g.signals, ctx)
      end
    end
  end

  # The two independent T1 reads. When the page has no text layer, local OCR
  # (CPU) and cheap vision (remote API) are independent — overlap them instead
  # of paying both latencies in sequence. With a layer, reader A is free.
  defp read_pair(image, "", game_id) do
    ocr = Task.async(fn -> ocr_one(image) end)
    vision = vision_one(image, game_id)
    # ocr_one has its own hard timeout and returns "" on failure; the extra
    # margin here only covers scheduler lag.
    {Task.await(ocr, @tesseract_timeout + 5_000), vision}
  end

  defp read_pair(image, layer, game_id), do: {layer, vision_one(image, game_id)}

  # T2 — the mid escalation ladder, run only after a T1 disagreement. Cheapest
  # move first: re-render the page sharper and re-read with the SAME cheap model
  # (most disagreements are resolution, not model capability). If a majority of
  # the reads now concur, that settles the page for the cost of one cheap read.
  # Still split → try the mid model on the same sharp image. Only a genuine
  # three/four-way conflict falls through to T3 (top model + critic).
  defp escalate_tiers(image, reads, signals, ctx) do
    case render_one_page(ctx.pdf_path, ctx.page, @t2_dpi) do
      {:ok, hi} ->
        try do
          # T2a: same cheap model, higher DPI. `reads` (indices 0,1) is the
          # original T1 pair that already disagreed on the fuller assess/2 test
          # (agreement + coverage + wordish) — exclude that exact pair from the
          # majority vote so it can't re-settle the page unsupported by any new
          # (higher-DPI) evidence.
          cheap_hi = vision_one(hi, ctx.game_id)

          case Gate.majority(reads ++ [cheap_hi], @t2_majority, exclude_pairs: [{0, 1}]) do
            {:ok, text} ->
              t2_result(text, signals)

            :none ->
              # T2b: mid model, same sharp image.
              mid = vision_one(hi, ctx.game_id, :mid)

              case Gate.majority(reads ++ [cheap_hi, mid], @t2_majority, exclude_pairs: [{0, 1}]) do
                {:ok, text} ->
                  t2_result(text, signals)

                :none ->
                  escalate_page(image, richest(reads ++ [cheap_hi, mid]),
                    signals: signals,
                    drift: false,
                    game_id: ctx.game_id
                  )
              end
          end
        after
          File.rm(hi)
        end

      # No sharper render available (no PDF path / render failure) → straight to T3.
      _ ->
        escalate_page(image, richest(reads), signals: signals, drift: false, game_id: ctx.game_id)
    end
  end

  # A T2 page settled by majority vote — resolved by agreement, not by the critic,
  # so confidence sits below a critic-verified read but above a bare cross-check.
  defp t2_result(text, signals) do
    Map.merge(
      %{text: text, confidence: 0.8, lane: "ensemble", source: "midtier", escalated: true},
      gate_detail(signals)
    )
  end

  @doc """
  Re-extracts a single page at the top tier: renders just that sheet (or uses the
  image directly), then runs the strong/high-res model + adversarial critic. For
  the admin "re-extract this page" action. Returns `{:ok, %{text, confidence,
  lane, source}}` or `{:error, reason}`.
  """
  def reextract_page(doc_path, sheet, opts \\ []) when is_integer(sheet) do
    full = Application.app_dir(:rule_maven, "priv/static/#{doc_path}")
    log = Keyword.get(opts, :on_log, fn _t, _k -> :ok end)
    label = Keyword.get(opts, :label, "sheet #{sheet}")

    cond do
      image?(doc_path) ->
        {:ok, escalate_page(full, "", on_log: log, game_id: opts[:game_id])}

      System.find_executable("pdftoppm") ->
        tmp = Application.app_dir(:rule_maven, "tmp/ocr")
        File.mkdir_p!(tmp)
        prefix = Path.join(tmp, "#{System.system_time(:millisecond)}_re")

        args =
          @jpeg_args ++
            [
              "-r",
              to_string(@reextract_dpi),
              "-f",
              to_string(sheet),
              "-l",
              to_string(sheet),
              full,
              prefix
            ]

        log.("Rendering #{label} at #{@reextract_dpi} DPI…", "info")

        case cmd("pdftoppm", args, @pdftoppm_timeout) do
          {:ok, {_, 0}} ->
            tmp
            |> File.ls!()
            |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
            |> Enum.sort()
            |> case do
              [img | _] ->
                path = Path.join(tmp, img)
                log.("Rendered #{label}.", "info")
                # try/after so the temp image is removed even if escalate_page raises.
                try do
                  {:ok, escalate_page(path, "", on_log: log, game_id: opts[:game_id])}
                after
                  File.rm(path)
                end

              [] ->
                {:error, "page #{sheet} did not render"}
            end

          _ ->
            {:error, "could not render page #{sheet}"}
        end

      true ->
        {:error, "no renderer available"}
    end
  end

  # Disagreement escalation: re-read the page with the strong/high-res model, take
  # the richer of that and the cheap candidate, then run the adversarial critic
  # loop. A critic-clean result is treated as the accuracy ceiling (high
  # confidence); residual defects are flagged for review. Runs only on
  # disagreement (or drift-sampled) pages, so the costly path stays bounded.
  # `opts[:signals]` (gate signals) + `opts[:drift]` enable calibration logging.
  #
  # A drift sample skips the critic: calibration only compares the strong read
  # to the cheap one (log_calibration), and the page's two readers already
  # agreed — the critic there was pure spend with no calibration value.
  defp escalate_page(image, cheap_text, opts) do
    log = Keyword.get(opts, :on_log, fn _t, _k -> :ok end)

    log.("Reading the page with the stronger model…", "info")

    strong =
      case RuleMaven.LLM.transcribe_page_image(image,
             model: RuleMaven.LLM.vision_model(:escalate),
             max_tokens: 8192,
             reasoning_effort: "low",
             game_id: opts[:game_id]
           ) do
        {:ok, t} -> t
        {:error, _} -> ""
      end

    if String.trim(strong) == "" do
      log.("Stronger model returned nothing — keeping the existing read.", "warn")
    else
      log.("Stronger model read complete.", "info")
    end

    candidate = richer(strong, cheap_text)

    if opts[:drift] do
      log_calibration(strong, cheap_text, opts)

      Map.merge(
        %{
          text: candidate,
          confidence: 0.85,
          lane: "ensemble",
          source: "drift_check",
          escalated: true
        },
        gate_detail(opts[:signals])
      )
    else
      escalate_with_critic(image, candidate, strong, cheap_text, opts, log)
    end
  end

  defp escalate_with_critic(image, candidate, strong, cheap_text, opts, log) do
    log.("Running the adversarial critic check…", "info")
    v = Critic.verify(image, candidate, game_id: opts[:game_id])

    if v.verified? do
      log.("Critic passed (#{v.rounds} round#{if v.rounds == 1, do: "", else: "s"}).", "done")
    else
      n = length(v.residual_defects)

      log.(
        "Critic left #{n} residual defect#{if n == 1, do: "", else: "s"} — page flagged for review.",
        "warn"
      )
    end

    log_calibration(strong, cheap_text, opts)

    # Decision-log detail: gate signals (when this came from the cross-check path,
    # not a bare re-extract), plus the critic outcome.
    detail =
      gate_detail(opts[:signals])
      |> Map.merge(%{
        escalated: true,
        critic_rounds: v.rounds,
        residual_defects: length(v.residual_defects)
      })

    if v.verified? do
      Map.merge(%{text: v.text, confidence: 0.9, lane: "ensemble", source: "critic"}, detail)
    else
      Map.merge(
        %{text: v.text, confidence: 0.5, lane: "ensemble", source: "critic_residual"},
        detail
      )
    end
  end

  # Gate signals as decision-log fields, or empty when absent (a bare
  # re-extract has no cross-check signals to report).
  defp gate_detail(%{agreement: a, coverage: c}),
    do: %{gate_agreement: Float.round(a, 3), gate_coverage: Float.round(c, 3)}

  defp gate_detail(_), do: %{}

  # Records the escalation outcome for calibration, when gate signals are present
  # (the cross-check path) and the strong read produced something to compare
  # against (a failed/empty strong read isn't a real material difference).
  defp log_calibration(strong, cheap, opts) do
    with %{} = signals <- opts[:signals],
         false <- String.trim(strong) == "" do
      jaccard = Gate.agreement(strong, cheap)
      cheap_tokens = length(Gate.tokens(cheap))
      strong_tokens = length(Gate.tokens(strong))

      Calibrate.log(%{
        agreement: signals.agreement,
        coverage: signals.coverage,
        cheap_wordish: max(signals.wordish_a, signals.wordish_b),
        cheap_tokens: cheap_tokens,
        strong_tokens: strong_tokens,
        jaccard_strong_cheap: jaccard,
        materially_differed: Calibrate.materially_differed?(jaccard, strong_tokens, cheap_tokens),
        drift_sample: opts[:drift] == true
      })
    else
      _ -> :ok
    end
  end

  # Pick the read with more real-word content (wordishness × token count, then
  # raw length as tiebreak). Never returns the emptier garbled read over a richer one.
  defp richer(a, b) do
    score = fn t -> {Gate.wordish_ratio(t) * length(Gate.tokens(t)), String.length(t)} end
    if score.(a) >= score.(b), do: a, else: b
  end

  # One-page local OCR (reader A when the page has no text layer). "" when
  # tesseract is absent or times out — the page then rides on the vision read.
  defp ocr_one(image) do
    if System.find_executable("tesseract") do
      case cmd("tesseract", [image, "stdout", "-l", "eng", "--psm", "6"], @tesseract_timeout,
             stderr_to_stdout: true
           ) do
        {:ok, {t, _}} -> t
        _ -> ""
      end
    else
      ""
    end
  end

  # One-page vision read. `tier` picks the model: :default (cheap, reader B and
  # T2a), :mid (T2b), :escalate (unused here — escalate_page reads directly). ""
  # on failure so a dead read never crashes the ladder.
  defp vision_one(image, game_id, tier \\ :default) do
    opts = [game_id: game_id]

    # Non-default tiers may resolve to a thinking model (mid falls back to the
    # escalate model when unset) — cap reasoning: transcription doesn't need it.
    opts =
      if tier == :default,
        do: opts,
        else: [{:model, RuleMaven.LLM.vision_model(tier)}, {:reasoning_effort, "low"} | opts]

    case RuleMaven.LLM.transcribe_page_image(image, opts) do
      {:ok, t} -> t
      {:error, _} -> ""
    end
  end

  # Richest read (most real-word content) of a non-empty list; "" for an empty
  # list. The candidate the critic (T3) compares its strong read against.
  defp richest([]), do: ""
  defp richest([h | t]), do: Enum.reduce(t, h, fn x, acc -> richer(x, acc) end)

  # Render one PDF sheet to a grayscale JPEG at `dpi` under tmp/ocr. The unique
  # suffix keeps concurrent page renders (@vision_concurrency) from colliding.
  # Caller deletes the image. {:ok, path} | {:error, reason}. nil pdf_path (a
  # single-image source, nothing to render) short-circuits so callers skip
  # render-dependent tiers.
  defp render_one_page(nil, _sheet, _dpi), do: {:error, :no_pdf}

  defp render_one_page(pdf_path, sheet, dpi) do
    if System.find_executable("pdftoppm") do
      tmp = Application.app_dir(:rule_maven, "tmp/ocr")
      File.mkdir_p!(tmp)
      prefix = Path.join(tmp, "#{System.unique_integer([:positive])}_t2")

      args =
        @jpeg_args ++
          ["-r", to_string(dpi), "-f", to_string(sheet), "-l", to_string(sheet), pdf_path, prefix]

      case cmd("pdftoppm", args, @pdftoppm_timeout) do
        {:ok, {_, 0}} ->
          tmp
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
          |> Enum.sort()
          |> case do
            [img | _] -> {:ok, Path.join(tmp, img)}
            [] -> {:error, :no_image}
          end

        _ ->
          {:error, :render_failed}
      end
    else
      {:error, :no_renderer}
    end
  end

  # Emit one detailed progress-log line through the same callback the worker
  # already passes. The worker handles `{:log, text, kind}`; the no-op sink
  # (direct callers) ignores it.
  defp log(on_progress, text, kind \\ :info), do: on_progress.({:log, text, kind})

  defp page_line(i, n, %{source: "text_layer"}), do: "Page #{i}/#{n} — clean text layer ✓"
  defp page_line(i, n, %{source: "crosscheck"}), do: "Page #{i}/#{n} — two reads agree ✓"

  defp page_line(i, n, %{source: "midtier"}),
    do: "Page #{i}/#{n} — readers disagreed → resolved by majority vote ✓"

  defp page_line(i, n, %{source: "drift_check"}),
    do: "Page #{i}/#{n} — drift-sampled: strong model cross-checked ✓"

  defp page_line(i, n, %{source: "critic"}),
    do: "Page #{i}/#{n} — readers disagreed → escalated & verified ✓"

  defp page_line(i, n, %{source: "critic_residual"}),
    do: "Page #{i}/#{n} — escalated, still uncertain — flagged for review ⚠"

  defp page_line(i, n, %{source: "error"}), do: "Page #{i}/#{n} — extraction error ✗"
  defp page_line(i, n, _), do: "Page #{i}/#{n} — read"

  defp page_kind(%{source: s}) when s in ["critic_residual", "error"], do: :warn
  defp page_kind(_), do: :page

  # Renders each PDF sheet to a grayscale PNG at @render_dpi under tmp/ocr,
  # returning {:ok, sorted_image_paths}. Caller deletes the images. Shared by the
  # vision and OCR paths so both get identical page rendering.
  defp render_pages(pdf_path) do
    tmp_dir = Application.app_dir(:rule_maven, "tmp/ocr")
    File.mkdir_p!(tmp_dir)
    prefix = Path.join(tmp_dir, "#{System.system_time(:millisecond)}_page")

    case cmd(
           "pdftoppm",
           @jpeg_args ++ ["-r", to_string(@render_dpi), pdf_path, prefix],
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

  defp run_ocr(full_path, on_progress, game_id) do
    on_progress.(:ocr)

    case ocr_text(full_path, game_id) do
      {:ok, text} -> {:ok, text, true, nil}
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

  defp ocr_text(pdf_path, game_id) do
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
                       @tesseract_timeout,
                       stderr_to_stdout: true
                     ) do
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
                if ocr_junk?(ocr), do: vision_or_ocr(img, ocr, game_id), else: ocr
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
  defp vision_or_ocr(image_path, ocr_text, game_id) do
    case RuleMaven.LLM.transcribe_page_image(image_path, game_id: game_id) do
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

  Delegates to `Extract.Gate.wordish_ratio/1` so the legacy OCR path and the
  cross-check engine classify garble identically (no drift between the two).
  """
  def ocr_junk?(text) do
    String.trim(text || "") == "" or Gate.wordish_ratio(text) < 0.5
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
