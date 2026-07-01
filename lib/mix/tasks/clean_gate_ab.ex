defmodule Mix.Tasks.CleanGateAb do
  @shortdoc "Sweep the clean_text_layer? threshold: vision calls saved vs drops risked"

  @moduledoc """
  Offline recalibration probe for `RuleMaven.Extract.Gate.clean_text_layer?/1`.

  Today a page is trusted without a vision cross-check only when its text layer
  scores `wordish >= 0.85`. Real rulebook prose scores ~0.73–0.81 (icons,
  numbers, card codes drag wordish down), so clean pages that would agree with
  vision anyway are forced to pay a vision call. This task quantifies the
  trade-off of lowering the bar.

  It reuses the reads already dumped by `mix docling_ab` under `tmp/docling_ab/`
  (`pageN_pdftotext.md` = text layer, `pageN_vision.md` = cheap vision) — so it
  makes **no new model calls**. For each page it treats the gate's own
  agreement verdict as ground truth for "was the vision call needed":

    * agreed  → the vision call was redundant; skipping it is a pure SAVING.
    * disagreed → vision caught something; skipping it is a RISKY drop.

  Then it sweeps a candidate wordish threshold and, at each level, counts safe
  skips vs risky skips — the curve you calibrate against.

      mix clean_gate_ab                       # sweep tmp/docling_ab/
      mix clean_gate_ab --dir tmp/other_dump
      mix clean_gate_ab --min-tokens 12       # also require token count to skip
  """
  use Mix.Task

  alias RuleMaven.Extract.Gate

  @thresholds [0.70, 0.72, 0.74, 0.76, 0.78, 0.80, 0.82, 0.85]

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [dir: :string, min_tokens: :integer])

    Mix.Task.run("app.start")

    dir = opts[:dir] || Path.join(["tmp", "docling_ab"])
    min_tokens = opts[:min_tokens] || 8
    full_dir = if Path.type(dir) == :absolute, do: dir, else: Path.join(File.cwd!(), dir)

    unless File.dir?(full_dir), do: Mix.raise("no dump dir: #{full_dir} (run mix docling_ab first)")

    pages = load_pages(full_dir)
    if pages == [], do: Mix.raise("no pageN_pdftotext.md / pageN_vision.md pairs in #{full_dir}")

    info("Dump: #{full_dir}")
    info("Pages: #{pages |> Enum.map(& &1.page) |> Enum.join(", ")}")
    info("Skip rule candidate: wordish >= T AND tokens >= #{min_tokens}\n")

    scored = Enum.map(pages, &score_page(&1, min_tokens))
    per_page(scored)
    sweep(scored, min_tokens)
  end

  defp load_pages(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^page\d+_pdftotext\.md$/))
    |> Enum.map(fn f ->
      n = f |> String.replace_prefix("page", "") |> String.replace_suffix("_pdftotext.md", "")
      vision = Path.join(dir, "page#{n}_vision.md")

      %{
        page: String.to_integer(n),
        layer: strip_header(File.read!(Path.join(dir, f))),
        vision: (File.exists?(vision) && strip_header(File.read!(vision))) || ""
      }
    end)
    |> Enum.sort_by(& &1.page)
  end

  # docling_ab writes raw reads with no header; older dumps may prepend a "# …"
  # banner. Drop a leading comment block if present, else return as-is.
  defp strip_header(text) do
    case String.split(text, "\n\n", parts: 2) do
      [head, rest] -> if String.starts_with?(head, "#"), do: rest, else: text
      _ -> text
    end
  end

  defp score_page(%{layer: layer, vision: vision} = p, min_tokens) do
    g = Gate.assess(layer, vision)

    Map.merge(p, %{
      wordish: Gate.wordish_ratio(layer),
      tokens: length(Gate.tokens(layer)),
      agreed?: g.agree?,
      current_clean?: Gate.clean_text_layer?(layer),
      eligible_tokens?: length(Gate.tokens(layer)) >= min_tokens
    })
  end

  defp per_page(scored) do
    info(String.duplicate("=", 78))
    info("PER PAGE")
    info(String.duplicate("=", 78))
    info("  page  wordish  tokens  agreed?  today-skips-vision?")

    Enum.each(scored, fn s ->
      info(
        "  #{pad(s.page, 4)}  #{pad(Float.round(s.wordish, 3), 7)}  " <>
          "#{pad(s.tokens, 6)}  #{pad(to_string(s.agreed?), 7)}  #{s.current_clean?}"
      )
    end)

    info("")
  end

  defp sweep(scored, _min_tokens) do
    info(String.duplicate("=", 78))
    info("THRESHOLD SWEEP  (skip vision when wordish >= T and token-eligible)")
    info(String.duplicate("=", 78))
    info("  Ground truth: agreed = vision was redundant; disagreed = vision needed.")
    info("    T      safe-skips   RISKY-skips   still-pays   note")

    Enum.each(@thresholds, fn t ->
      skipped = Enum.filter(scored, &(&1.eligible_tokens? and &1.wordish >= t))
      safe = Enum.count(skipped, & &1.agreed?)
      risky = Enum.count(skipped, &(not &1.agreed?))
      still_pays = length(scored) - length(skipped)

      note =
        cond do
          risky > 0 -> "⚠ drops #{risky} page(s) that needed vision"
          safe > 0 -> "saves #{safe} vision call(s), no drop"
          true -> "no change"
        end

      flag = if t == 0.85, do: " (current)", else: ""

      info(
        "  #{pad(Float.round(t, 2), 5)}  #{pad(safe, 10)}   #{pad(risky, 11)}   " <>
          "#{pad(still_pays, 10)}   #{note}#{flag}"
      )
    end)

    disagreed = Enum.count(scored, &(not &1.agreed?))

    info("")

    if disagreed == 0 do
      info(
        "  NOTE: 0/#{length(scored)} pages disagreed with vision — this dump has no " <>
          "risk cases, so the RISKY column is unproven. Feed it pages where the text " <>
          "layer drops/mangles content (scanned, heavy-table, sidebar-broken) to test the downside."
      )
    end
  end

  defp pad(v, n), do: String.pad_trailing(to_string(v), n)
  defp info(msg), do: Mix.shell().info(msg)
end
