defmodule Mix.Tasks.DoclingAb do
  @shortdoc "A/B the Docling reader lane against pdftotext on gate escalation rate"

  @moduledoc """
  Measures whether adding **Docling** (local layout model) as the gate's cheap
  `reader_a` lowers the escalation rate versus today's `pdftotext` layer.

  For each page it produces three reads — `pdftotext -layout` (today's cheap
  reader), the Docling sidecar (candidate reader), and one cheap vision read —
  then runs the *real* `RuleMaven.Extract.Gate` on both pairings and reports who
  would escalate. Escalation is the expensive path (`escalate_page` → strong
  model + critic), so fewer escalations = direct cost win.

  It changes nothing in production; it only scores. Wire Docling into
  `decide_page/4` only if the numbers here justify the new dependency.

      DOCLING_PYTHON=priv/docling/.venv/bin/python \\
        mix docling_ab --pdf priv/static/uploads/rulebooks/foo.pdf --pages 1,5,9

  Set the sidecar interpreter via `--docling-python` or `DOCLING_PYTHON`
  (defaults to `priv/docling/.venv/bin/python`). See priv/docling/README.md.

  Full reads for each page are written under `tmp/docling_ab/`.
  """
  use Mix.Task

  alias RuleMaven.Extract.Gate

  @default_pages "1,5,9"
  @render_dpi 300
  @sidecar "priv/docling/docling_page.py"
  @default_python "priv/docling/.venv/bin/python"

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [pdf: :string, pages: :string, docling_python: :string]
      )

    Mix.Task.run("app.start")

    pdf = opts[:pdf] || Mix.raise("--pdf required")
    full_pdf = if Path.type(pdf) == :absolute, do: pdf, else: Path.join(File.cwd!(), pdf)
    python = opts[:docling_python] || System.get_env("DOCLING_PYTHON") || @default_python

    pages =
      (opts[:pages] || @default_pages)
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer(String.trim(&1)))

    unless File.exists?(full_pdf), do: Mix.raise("PDF not found: #{full_pdf}")
    unless System.find_executable("pdftoppm"), do: Mix.raise("pdftoppm not on PATH")
    unless System.find_executable("pdftotext"), do: Mix.raise("pdftotext not on PATH")
    preflight_docling(python)

    out_dir = Path.join([File.cwd!(), "tmp", "docling_ab"])
    File.mkdir_p!(out_dir)

    info("PDF: #{full_pdf}")
    info("Docling python: #{python}")
    info("Pages: #{Enum.join(pages, ", ")}\n")

    results = Enum.map(pages, &run_page(full_pdf, &1, python, out_dir))
    summarize(results)
    info("\nFull reads written under #{out_dir}/")
  end

  defp run_page(full_pdf, page, python, out_dir) do
    info(String.duplicate("=", 70))
    info("PAGE #{page}")
    info(String.duplicate("=", 70))

    layer = pdftotext_page(full_pdf, page)
    docling = docling_page(full_pdf, page, python)

    vision =
      case render_page(full_pdf, page) do
        {:ok, image} ->
          v = vision_one(image)
          File.rm(image)
          v

        {:error, reason} ->
          info("  render failed: #{inspect(reason)} — vision skipped")
          ""
      end

    write(out_dir, page, "pdftotext", layer)
    write(out_dir, page, "docling", docling)
    write(out_dir, page, "vision", vision)

    current = decision(layer, vision)
    candidate = decision(docling, vision)

    info("  pdftotext: #{String.length(layer)} chars, wordish #{wr(layer)}")
    info("  docling:   #{String.length(docling)} chars, wordish #{wr(docling)}")
    info("  vision:    #{String.length(vision)} chars, wordish #{wr(vision)}")
    info("")
    info("  CURRENT   (pdftotext vs vision): #{fmt(current)}")
    info("  CANDIDATE (docling   vs vision): #{fmt(candidate)}")
    info("  → #{verdict(current, candidate)}\n")

    %{page: page, current: current, candidate: candidate}
  end

  # Mirror production decide_page/4: a clean text layer is trusted with no vision
  # call (no escalation); otherwise the two reads are scored by the gate.
  defp decision(reader, vision) do
    reader = String.trim(reader)

    if Gate.clean_text_layer?(reader) do
      %{outcome: :trust_layer, escalate?: false, agreement: nil, coverage: nil}
    else
      g = Gate.assess(reader, vision)

      %{
        outcome: if(g.escalate?, do: :escalate, else: :agree),
        escalate?: g.escalate?,
        agreement: g.signals.agreement,
        coverage: g.signals.coverage
      }
    end
  end

  defp summarize(results) do
    n = length(results)
    cur = Enum.count(results, & &1.current.escalate?)
    cand = Enum.count(results, & &1.candidate.escalate?)

    flipped_saved = Enum.count(results, &(&1.current.escalate? and not &1.candidate.escalate?))
    flipped_added = Enum.count(results, &(not &1.current.escalate? and &1.candidate.escalate?))

    info(String.duplicate("=", 70))
    info("SUMMARY (#{n} pages)")
    info(String.duplicate("=", 70))
    info("  escalations — current (pdftotext): #{cur}/#{n}  (#{pct(cur, n)})")
    info("  escalations — candidate (docling): #{cand}/#{n}  (#{pct(cand, n)})")
    info("  pages docling SAVED from escalation: #{flipped_saved}")
    info("  pages docling ADDED to escalation:   #{flipped_added}")

    info(
      "  net escalation delta: #{if cand - cur <= 0, do: "", else: "+"}#{cand - cur} " <>
        "(negative = docling cheaper)"
    )
  end

  # ---- readers ----

  defp pdftotext_page(pdf, page) do
    args = ["-layout", "-f", to_string(page), "-l", to_string(page), pdf, "-"]

    case System.cmd("pdftotext", args, stderr_to_stdout: true) do
      {text, 0} -> text
      _ -> ""
    end
  end

  defp docling_page(pdf, page, python) do
    args = [Path.join(File.cwd!(), @sidecar), "--pdf", pdf, "--page", to_string(page)]

    case System.cmd(python, args, stderr_to_stdout: false) do
      {md, 0} ->
        md

      {_, code} ->
        info("  docling exit #{code} on page #{page} — treated as empty read")
        ""
    end
  rescue
    e ->
      info("  docling call raised: #{Exception.message(e)} — empty read")
      ""
  end

  defp vision_one(image) do
    case RuleMaven.LLM.transcribe_page_image(image) do
      {:ok, t} -> t
      {:error, reason} -> info("  vision error: #{inspect(reason)}") && ""
    end
  end

  defp render_page(full_pdf, page) do
    tmp = Path.join([File.cwd!(), "tmp", "docling_ab"])
    File.mkdir_p!(tmp)
    prefix = Path.join(tmp, "p#{page}_#{System.system_time(:millisecond)}")

    args = [
      "-png",
      "-gray",
      "-r",
      to_string(@render_dpi),
      "-f",
      to_string(page),
      "-l",
      to_string(page),
      full_pdf,
      prefix
    ]

    case System.cmd("pdftoppm", args, stderr_to_stdout: true) do
      {_, 0} ->
        tmp
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, Path.basename(prefix)))
        |> Enum.sort()
        |> case do
          [img | _] -> {:ok, Path.join(tmp, img)}
          [] -> {:error, :no_image}
        end

      {out, code} ->
        {:error, "pdftoppm exit #{code}: #{out}"}
    end
  end

  # ---- preflight / formatting ----

  defp preflight_docling(python) do
    exe = if Path.type(python) == :absolute, do: python, else: Path.join(File.cwd!(), python)

    unless File.exists?(exe) do
      Mix.raise(
        "Docling python not found at #{python}. Build the venv " <>
          "(see priv/docling/README.md) or pass --docling-python."
      )
    end
  end

  defp fmt(%{outcome: :trust_layer}), do: "trust clean layer — no vision, no escalation"

  defp fmt(%{outcome: outcome, agreement: a, coverage: c}) do
    tag = if outcome == :escalate, do: "ESCALATE 💸", else: "agree ✓"
    "#{tag}  (agreement #{Float.round(a, 2)}, coverage #{Float.round(c, 2)})"
  end

  defp verdict(%{escalate?: true}, %{escalate?: false}), do: "docling SAVES an escalation ✅"
  defp verdict(%{escalate?: false}, %{escalate?: true}), do: "docling ADDS an escalation ⚠"
  defp verdict(_, _), do: "no change"

  defp wr(text), do: Float.round(Gate.wordish_ratio(text), 2)
  defp pct(_, 0), do: "0%"
  defp pct(x, n), do: "#{round(x / n * 100)}%"

  defp write(dir, page, role, text) do
    File.write!(Path.join(dir, "page#{page}_#{role}.md"), text || "")
  end

  defp info(msg), do: Mix.shell().info(msg)
end
