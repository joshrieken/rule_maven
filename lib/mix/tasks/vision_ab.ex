defmodule Mix.Tasks.VisionAb do
  @shortdoc "A/B two vision models on rulebook page transcription"

  @moduledoc """
  Renders rulebook PDF pages to images (same recipe as the extraction pipeline:
  300 DPI grayscale PNG via pdftoppm) and transcribes each page with two vision
  models, then prints a per-page diff so you can judge accuracy loss before
  swapping the production `llm_vision_model_*` setting.

      mix vision_ab                         # summer camp, pages 1,5,9, flash vs flash-lite
      mix vision_ab --pages 1,2,3
      mix vision_ab --pdf priv/static/uploads/rulebooks/foo.pdf --pages 4
      mix vision_ab --baseline google/gemini-2.5-flash --candidate google/gemini-2.5-flash-lite

  Full transcriptions for each page/model are written to
  `tmp/vision_ab/` so you can eyeball them side by side.
  """
  use Mix.Task

  @default_pdf "priv/static/uploads/rulebooks/1782576838256_SummerCampInstructions.pdf"
  @default_pages "1,5,9"
  @default_baseline "google/gemini-2.5-flash"
  @default_candidate "google/gemini-2.5-flash-lite"
  @render_dpi 300

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [pdf: :string, pages: :string, baseline: :string, candidate: :string]
      )

    Mix.Task.run("app.start")

    pdf = opts[:pdf] || @default_pdf
    full_pdf = if Path.type(pdf) == :absolute, do: pdf, else: Path.join(File.cwd!(), pdf)
    baseline = opts[:baseline] || @default_baseline
    candidate = opts[:candidate] || @default_candidate

    pages =
      (opts[:pages] || @default_pages)
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer(String.trim(&1)))

    unless File.exists?(full_pdf), do: Mix.raise("PDF not found: #{full_pdf}")
    unless System.find_executable("pdftoppm"), do: Mix.raise("pdftoppm not on PATH")

    out_dir = Path.join([File.cwd!(), "tmp", "vision_ab"])
    File.mkdir_p!(out_dir)

    info("PDF: #{full_pdf}")
    info("Baseline:  #{baseline}")
    info("Candidate: #{candidate}")
    info("Pages: #{Enum.join(pages, ", ")}\n")

    Enum.each(pages, fn page ->
      run_page(full_pdf, page, baseline, candidate, out_dir)
    end)

    info("\nFull outputs written under #{out_dir}/")
  end

  defp run_page(full_pdf, page, baseline, candidate, out_dir) do
    info(String.duplicate("=", 70))
    info("PAGE #{page}")
    info(String.duplicate("=", 70))

    with {:ok, image} <- render_page(full_pdf, page) do
      base_res = transcribe(image, baseline)
      cand_res = transcribe(image, candidate)
      File.rm(image)

      write(out_dir, page, "baseline", baseline, base_res)
      write(out_dir, page, "candidate", candidate, cand_res)

      report(base_res, cand_res)
    else
      {:error, reason} -> info("  render failed: #{inspect(reason)}")
    end
  end

  defp render_page(full_pdf, page) do
    tmp = Path.join([File.cwd!(), "tmp", "vision_ab"])
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

  defp transcribe(image, model) do
    {micros, result} =
      :timer.tc(fn -> RuleMaven.LLM.transcribe_page_image(image, model: model) end)

    case result do
      {:ok, text} -> %{ok: true, text: text, ms: div(micros, 1000)}
      {:error, reason} -> %{ok: false, text: "", error: reason, ms: div(micros, 1000)}
    end
  end

  defp report(base, cand) do
    info("\n  baseline:  #{stats(base)}")
    info("  candidate: #{stats(cand)}\n")

    if base.ok and cand.ok do
      base_lines = norm_lines(base.text)
      cand_lines = norm_lines(cand.text)
      base_set = MapSet.new(base_lines)
      cand_set = MapSet.new(cand_lines)

      only_base = base_lines |> Enum.reject(&MapSet.member?(cand_set, &1)) |> Enum.uniq()
      only_cand = cand_lines |> Enum.reject(&MapSet.member?(base_set, &1)) |> Enum.uniq()

      info("  numbers in baseline:  #{numbers(base.text)}")
      info("  numbers in candidate: #{numbers(cand.text)}")
      info("  table rows  base/cand: #{table_rows(base.text)} / #{table_rows(cand.text)}\n")

      print_lines("LINES ONLY IN BASELINE (candidate may have missed)", only_base)
      print_lines("LINES ONLY IN CANDIDATE (possible hallucination/reword)", only_cand)
    end
  end

  defp stats(%{ok: false, error: e, ms: ms}), do: "ERROR (#{ms}ms): #{inspect(e)}"

  defp stats(%{ok: true, text: t, ms: ms}) do
    "#{byte_size(t)} chars, #{length(String.split(t, "\n"))} lines, #{ms}ms"
  end

  # Normalize for set comparison: trim, collapse whitespace, drop blanks/short noise.
  defp norm_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(String.replace(&1, ~r/\s+/, " ") |> String.trim()))
    |> Enum.reject(&(String.length(&1) < 4))
  end

  defp numbers(text), do: Regex.scan(~r/\d+/, text) |> length()
  defp table_rows(text), do: text |> String.split("\n") |> Enum.count(&String.contains?(&1, "|"))

  defp print_lines(_title, []), do: :ok

  defp print_lines(title, lines) do
    info("  --- #{title} (#{length(lines)}) ---")
    lines |> Enum.take(25) |> Enum.each(fn l -> info("    #{l}") end)
    if length(lines) > 25, do: info("    … #{length(lines) - 25} more")
    info("")
  end

  defp write(dir, page, role, model, %{text: text} = res) do
    name = "page#{page}_#{role}.txt"
    header = "# page #{page} — #{role} — #{model}\n# #{stats(res)}\n\n"
    File.write!(Path.join(dir, name), header <> text)
  end

  defp info(msg), do: Mix.shell().info(msg)
end
