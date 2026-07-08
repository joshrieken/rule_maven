defmodule RuleMaven.Setup do
  @moduledoc """
  Generates a tappable "set up the game" checklist from a rulebook: the
  components to gather and the ordered setup steps. Mirrors the CheatSheet
  Settings state-machine pattern — generation is durable (Oban) and the result
  is cached in `Settings` under `setup_*_<game_id>` keys.

  Stored content is JSON: `%{"components" => [string], "setup" => [%{"title",
  "detail"}]}`.
  """

  alias RuleMaven.{Games, Settings, LLM}

  @doc "Seeds the state machine and enqueues durable generation."
  def generate_async(game) do
    game_id = game.id
    Settings.put("setup_status_#{game_id}", "generating")
    Settings.put("setup_content_#{game_id}", nil)
    Settings.put("setup_error_#{game_id}", nil)

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id}
      |> RuleMaven.Workers.SetupChecklistWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  def topic(game_id), do: "setup:#{game_id}"

  def status(game_id), do: Settings.get("setup_status_#{game_id}")
  def stored_error(game_id), do: Settings.get("setup_error_#{game_id}")

  @doc "Parsed checklist `%{components, setup}` or nil."
  def stored_checklist(game_id) do
    case Settings.get("setup_content_#{game_id}") do
      nil -> nil
      json -> decode(json)
    end
  end

  def clear(game_id) do
    Settings.put("setup_status_#{game_id}", nil)
    Settings.put("setup_content_#{game_id}", nil)
    Settings.put("setup_error_#{game_id}", nil)
  end

  @doc """
  Generates the checklist content. Returns `{:ok, json_string}` or
  `{:error, reason}`.
  """
  def generate_content(game) do
    text = Games.rulebook_text(game)

    if String.trim(text) == "" do
      {:error, "No rulebook text available for #{game.name}"}
    else
      # Setup + components live early in most rulebooks; cap the input. Keep this
      # modest (≈16k) — a larger context makes the reasoning model slow enough to
      # hit the HTTP timeout, and adds little since setup is front-loaded.
      source = String.slice(text, 0, 16_000)

      system = RuleMaven.Prompts.template("setup_generate_system")

      # Plain-text bullets, NOT JSON, and deliberately loosely specified. A strict
      # "output only JSON" instruction — or an over-structured spec — makes our
      # reasoning model (deepseek-v4-flash) spend its whole budget "thinking" and
      # return empty content. A simple labelled-bullet ask generates reliably.
      prompt =
        RuleMaven.Prompts.render("setup_generate", %{game_name: game.name, rulebook: source})

      # Generous budget for the reasoning-model overhead (see Did-you-know).
      case LLM.chat(prompt, "setup_#{game.name}",
             operation: "setup",
             game_id: game.id,
             system: system,
             max_tokens: 8000
           ) do
        {:ok, content} ->
          case parse_sections(content) do
            nil -> {:error, "Could not parse the setup checklist. Please retry."}
            map -> {:ok, Jason.encode!(verify_checklist(game, text, map))}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Parse the model's two-section bullet text into the stored shape
  # `%{"components" => [string], "setup" => [%{"title", "detail"}]}`. Returns nil
  # when neither section yields any items. Public only so the parser can be
  # tested against real model output shapes; not part of the public API.
  @doc false
  def parse_sections(content) do
    lines = String.split(to_string(content), ~r/\r?\n/)

    {components, steps, _section} =
      Enum.reduce(lines, {[], [], nil}, fn line, {comps, steps, section} ->
        trimmed = String.trim(line)
        header = normalize_header(trimmed)
        item = trimmed |> bullet_text() |> strip_md()

        cond do
          # Section headers are non-bullet lines. Match loosely: the model often
          # wraps them in markdown (**, ##) or uses synonyms ("Components needed",
          # "Setup steps", "Game setup"). Guard on is_nil(item) so a bulleted line
          # like "- Setup the board" isn't mistaken for the "setup" header.
          is_nil(item) and String.starts_with?(header, "component") ->
            {comps, steps, :components}

          is_nil(item) and
              (String.starts_with?(header, "step") or String.contains?(header, "setup")) ->
            {comps, steps, :steps}

          item == nil ->
            {comps, steps, section}

          section == :components ->
            {[item | comps], steps, section}

          section == :steps ->
            {comps, [parse_step(item) | steps], section}

          true ->
            {comps, steps, section}
        end
      end)

    components = Enum.reverse(components)
    steps = steps |> Enum.reverse() |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))

    if components == [] and steps == [],
      do: parse_headerless(lines),
      else: %{"components" => components, "setup" => steps}
  end

  # The reasoning model sometimes emits both lists as one bare bullet run with
  # no section headers at all (seen with Ethnos: 2nd Edition), which the header
  # scan above can't place. Classify each bullet instead: count-prefixed lines
  # ("144 Ally Cards") are components, everything else is a setup step. A
  # miscall is tolerable — the verify pass fact-checks every item afterwards.
  defp parse_headerless(lines) do
    items =
      lines
      |> Enum.map(fn line -> line |> String.trim() |> bullet_text() |> strip_md() end)
      |> Enum.reject(&is_nil/1)

    {components, steps} = Enum.split_with(items, &Regex.match?(~r/^\d+\s/, &1))

    steps =
      steps
      |> Enum.map(&parse_step/1)
      |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))

    if components == [] and steps == [],
      do: nil,
      else: %{"components" => components, "setup" => steps}
  end

  # Normalize a potential section header to bare lowercase words: strip markdown
  # emphasis/heading marks (*, #, _, `) and a trailing colon so "**Components:**"
  # and "## Setup Steps" still match.
  defp normalize_header(line) do
    line
    |> String.downcase()
    |> String.replace(~r/[*#_`]/, "")
    |> String.trim()
    |> String.trim_trailing(":")
    |> String.trim()
  end

  # Remove surrounding markdown emphasis from item text (e.g. "**Board**").
  defp strip_md(nil), do: nil
  defp strip_md(text), do: text |> String.replace(~r/[*_`]/, "") |> String.trim()

  # Strip a leading bullet/number marker; nil if the line isn't a list item.
  defp bullet_text(line) do
    case Regex.run(~r/^\s*(?:[-*•]|\d+[.)])\s+(.*\S)\s*$/, line) do
      [_, text] -> text
      _ -> nil
    end
  end

  # Split a step into title + detail on the first em/en dash, colon, or " - ".
  defp parse_step(item) do
    case Regex.split(~r/\s+[—–-]\s+|:\s+/u, item, parts: 2) do
      [title, detail] -> %{"title" => String.trim(title), "detail" => String.trim(detail)}
      [title] -> %{"title" => String.trim(title), "detail" => ""}
    end
  end

  # Second-pass fact-check: drop any component/step not fully & accurately
  # supported by the rulebook (a wrong setup step is worse than a missing one).
  # Fail-open — a verify error, an unparseable reply, OR a reply that would drop
  # the ENTIRE checklist keeps the original (a real game always has some valid
  # setup, so an all-empty result means the checker misfired, not a bad list).
  defp verify_checklist(
         %{name: game_name, id: game_id},
         text,
         %{"components" => comps, "setup" => steps} = map
       ) do
    comp_texts = comps
    step_texts = Enum.map(steps, &step_text/1)
    items = comp_texts ++ step_texts

    if items == [] do
      map
    else
      numbered =
        items
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {it, i} -> "#{i}. #{it}" end)

      prompt =
        RuleMaven.Prompts.render("setup_verify", %{
          game_name: game_name,
          rulebook: String.slice(to_string(text), 0, 24_000),
          items: numbered
        })

      case LLM.chat(prompt, "setup_verify_#{game_name}",
             operation: "setup",
             game_id: game_id,
             system:
               "You are a strict board-game rulebook fact-checker. Pass only setup items that are fully and accurately supported; reject anything misleading, garbled, or unconfirmed.",
             max_tokens: 600
           ) do
        {:ok, out} ->
          case keep_indices(out) do
            :all ->
              map

            keep ->
              nc = length(comps)
              kept_comps = filter_by_index(comps, 1, keep)
              kept_steps = filter_by_index(steps, nc + 1, keep)

              # Guard: never let the checker wipe the whole checklist.
              if kept_comps == [] and kept_steps == [],
                do: map,
                else: %{map | "components" => kept_comps, "setup" => kept_steps}
          end

        {:error, _} ->
          map
      end
    end
  end

  defp verify_checklist(_game, _text, map), do: map

  defp step_text(%{"title" => t, "detail" => d}) do
    [t, d] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")
  end

  defp step_text(other), do: to_string(other)

  # Keep list elements whose 1-based position (starting at `offset`) is in `keep`.
  defp filter_by_index(list, offset, keep) do
    list
    |> Enum.with_index(offset)
    |> Enum.filter(fn {_, i} -> MapSet.member?(keep, i) end)
    |> Enum.map(&elem(&1, 0))
  end

  # Parse the checker's "1,2,5" / "none" reply. :all on an unparseable non-"none"
  # reply (fail-open); empty set only on an explicit "none".
  defp keep_indices(text) do
    trimmed = String.trim(text || "")

    cond do
      Regex.match?(~r/^\s*none\b/i, trimmed) ->
        MapSet.new()

      true ->
        nums = Regex.scan(~r/\d+/, trimmed) |> Enum.map(fn [n] -> String.to_integer(n) end)
        if nums == [], do: :all, else: MapSet.new(nums)
    end
  end

  # Tolerant decode: strips ```json fences / stray prose around the object.
  defp decode(content) do
    with json when is_binary(json) <- extract_json(content),
         {:ok, %{} = map} <- Jason.decode(json) do
      %{
        "components" => string_list(map["components"]),
        "setup" => step_list(map["setup"])
      }
    else
      _ -> nil
    end
  end

  defp extract_json(content) do
    case Regex.run(~r/\{.*\}/s, to_string(content)) do
      [json] -> json
      _ -> nil
    end
  end

  defp string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp string_list(_), do: []

  defp step_list(v) when is_list(v) do
    v
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn s ->
      %{"title" => to_string(s["title"]), "detail" => to_string(s["detail"])}
    end)
    |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
  end

  defp step_list(_), do: []
end
