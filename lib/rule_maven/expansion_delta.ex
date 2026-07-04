defmodule RuleMaven.ExpansionDelta do
  @moduledoc """
  Generates a per-expansion "what this expansion changes" delta from the
  expansion's own rulebook: new components, setup changes, and rule changes.
  Generated once per expansion (durable Oban worker) and composed at display
  time into the BASE game's setup checklist and cheat sheet for whichever
  expansion set the viewer selected — linear cost in the number of
  expansions, never per-combo.

  Mirrors the Setup/CheatSheet Settings state-machine pattern; keys are
  `delta_*_<expansion_game_id>`. Stored content is JSON:
  `%{"components" => [string], "setup" => [%{"title","detail"}],
  "rules" => [string]}`.
  """

  alias RuleMaven.{Games, Settings, LLM}

  @doc "Seeds the state machine and enqueues durable generation."
  def generate_async(game) do
    game_id = game.id
    Settings.put("delta_status_#{game_id}", "generating")
    Settings.put("delta_content_#{game_id}", nil)
    Settings.put("delta_error_#{game_id}", nil)

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id}
      |> RuleMaven.Workers.ExpansionDeltaWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  def topic(game_id), do: "delta:#{game_id}"

  def status(game_id), do: Settings.get("delta_status_#{game_id}")
  def stored_error(game_id), do: Settings.get("delta_error_#{game_id}")

  @doc "Parsed delta `%{components, setup, rules}` or nil."
  def stored(game_id) do
    case Settings.get("delta_content_#{game_id}") do
      nil -> nil
      json -> decode(json)
    end
  end

  def clear(game_id) do
    Settings.put("delta_status_#{game_id}", nil)
    Settings.put("delta_content_#{game_id}", nil)
    Settings.put("delta_error_#{game_id}", nil)
  end

  @doc """
  Generates the delta content from the expansion's own rulebook. Returns
  `{:ok, json_string}` or `{:error, reason}`.
  """
  def generate_content(game) do
    text = Games.rulebook_text(game)

    if String.trim(text) == "" do
      {:error, "No rulebook text available for #{game.name}"}
    else
      # Changes cluster early (setup + "what's new") but rule overrides can sit
      # deeper than base-game setup does — give it more room than Setup's 16k.
      source = String.slice(text, 0, 24_000)

      system = RuleMaven.Prompts.template("expansion_delta_system")

      prompt =
        RuleMaven.Prompts.render("expansion_delta", %{game_name: game.name, rulebook: source})

      case LLM.chat(prompt, "expansion_delta_#{game.name}",
             operation: "expansion_delta",
             game_id: game.id,
             system: system,
             max_tokens: 8000
           ) do
        {:ok, content} ->
          case parse_sections(content) do
            nil -> {:error, "Could not parse the expansion delta. Please retry."}
            map -> {:ok, Jason.encode!(map)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Parse the model's three-section bullet text into the stored shape. Returns
  # nil when no section yields any items. Public only for tests.
  @doc false
  def parse_sections(content) do
    lines = String.split(to_string(content), ~r/\r?\n/)

    {comps, setup, rules, _section} =
      Enum.reduce(lines, {[], [], [], nil}, fn line, {comps, setup, rules, section} ->
        trimmed = String.trim(line)
        header = normalize_header(trimmed)
        item = trimmed |> bullet_text() |> strip_md()

        cond do
          is_nil(item) and String.starts_with?(header, "component") ->
            {comps, setup, rules, :components}

          is_nil(item) and String.starts_with?(header, "rule") ->
            {comps, setup, rules, :rules}

          is_nil(item) and
              (String.starts_with?(header, "step") or String.contains?(header, "setup")) ->
            {comps, setup, rules, :setup}

          item == nil ->
            {comps, setup, rules, section}

          section == :components ->
            {[item | comps], setup, rules, section}

          section == :setup ->
            {comps, [parse_step(item) | setup], rules, section}

          section == :rules ->
            {comps, setup, [item | rules], section}

          true ->
            {comps, setup, rules, section}
        end
      end)

    comps = Enum.reverse(comps)
    setup = setup |> Enum.reverse() |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
    rules = Enum.reverse(rules)

    if comps == [] and setup == [] and rules == [],
      do: nil,
      else: %{"components" => comps, "setup" => setup, "rules" => rules}
  end

  # ── shared shapes with Setup's parser ──

  defp normalize_header(line) do
    line
    |> String.downcase()
    |> String.replace(~r/[*#_`]/, "")
    |> String.trim()
    |> String.trim_trailing(":")
    |> String.trim()
  end

  defp strip_md(nil), do: nil
  defp strip_md(text), do: text |> String.replace(~r/[*_`]/, "") |> String.trim()

  defp bullet_text(line) do
    case Regex.run(~r/^\s*(?:[-*•]|\d+[.)])\s+(.*\S)\s*$/, line) do
      [_, text] -> text
      _ -> nil
    end
  end

  defp parse_step(item) do
    case Regex.split(~r/\s+[—–-]\s+|:\s+/u, item, parts: 2) do
      [title, detail] -> %{"title" => String.trim(title), "detail" => String.trim(detail)}
      [title] -> %{"title" => String.trim(title), "detail" => ""}
    end
  end

  # Tolerant decode: strips fences/prose around the JSON object.
  defp decode(content) do
    with json when is_binary(json) <- extract_json(content),
         {:ok, %{} = map} <- Jason.decode(json) do
      %{
        "components" => string_list(map["components"]),
        "setup" => step_list(map["setup"]),
        "rules" => string_list(map["rules"])
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
    |> Enum.map(fn s -> %{"title" => to_string(s["title"]), "detail" => to_string(s["detail"])} end)
    |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
  end

  defp step_list(_), do: []
end
