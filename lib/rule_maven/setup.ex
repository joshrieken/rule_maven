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
      # Setup + components live early in most rulebooks; cap the input.
      source = String.slice(text, 0, 30_000)

      system =
        "You extract game setup instructions. Output ONLY valid JSON, no prose, no code fences."

      prompt = """
      From this rulebook for "#{game.name}", produce a setup checklist as JSON with this exact shape:
      {
        "components": ["short item a player must get out / sort / place", ...],
        "setup": [{"title": "short imperative step", "detail": "one-sentence how-to"}, ...]
      }

      Rules:
      - "components": physical things to gather or sort before play (board, decks, tokens, starting hands). 4-12 short items.
      - "setup": the ordered steps to set up a game, first to last. 4-12 steps. "title" is a tappable one-liner; "detail" is a single clarifying sentence (numbers in plain text).
      - Use ONLY what the rulebook states. Do not invent. If something is unknown, omit it.
      - No markdown, no commentary. JSON only.

      RULEBOOK:
      #{source}
      """

      case LLM.chat(prompt, "setup_#{game.name}", system: system, max_tokens: 1200) do
        {:ok, content} ->
          case decode(content) do
            nil -> {:error, "Could not parse the setup checklist. Please retry."}
            _ok -> {:ok, extract_json(content)}
          end

        {:error, reason} ->
          {:error, reason}
      end
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
    |> Enum.map(fn s -> %{"title" => to_string(s["title"]), "detail" => to_string(s["detail"])} end)
    |> Enum.reject(&(&1["title"] in [nil, "", "nil"]))
  end

  defp step_list(_), do: []
end
