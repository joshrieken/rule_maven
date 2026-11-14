defmodule RuleMaven.ManualImport.Enrichments do
  @moduledoc """
  Imports hand-authored Prepare enrichments (the content the enrichment workers
  would otherwise generate with an LLM) through the same storage calls those
  workers make, so each step reads as complete and the page renders it.

  Input is a map keyed by step (any subset):

      "suggestions"     [%{"category", "questions" => [str]}]
      "categories"      [%{"name", "description"}]          # embeds via API
      "cheat_sheet"     markdown string (≤ 10k chars)
      "setup"           %{"components" => [str], "setup" => [%{"title", "detail"}]}
      "did_you_know"    [str]
      "voices"          [%{"label", "emoji", "style", "description",
                           "loading_phrases", "thanks_phrases"}]
      "first_player"    [str]
      "common_mistakes" [%{"wrong", "right"}]
      "quiz"            [%{"q", "choices" => [str], "answer" => int, "why"}]
      "teach"           %{"goal", "loop", "win", "trap"}
      "score"           [%{"label", "hint"}]                # [] = not a points game
      "turn"            [%{"name", "note", "actions" => [%{"label", "rule"}]}]
      "expansion_delta" %{"components" => [str], "setup" => [%{"title", "detail"}],
                          "rules" => [str]}           # expansions only
      "theme"           %{"sets" => [%{"light" => anchors, "dark" => anchors,
                          "names" => %{"light", "dark"}}]}  # base games only;
                          # anchors = %{"accent", "bg", "surface", "text"} hex,
                          # picked from the cover (ThemePalette derives the rest)
      "symbols"         [%{"token", "name", "meaning", "aliases" => [str], "page",
                           "image_base64" | "image_path"}]   # [] = book has none
                          # every token must occur in the game's rulebook text;
                          # image_path (a local file) is for the mix task only

  Every step is validated before anything is written; one bad step aborts the
  whole import with `{:error, {step, reason}}`.
  """

  alias RuleMaven.{CheatSheet, Games, Readiness, Settings, ThemePalette, Voices}
  alias RuleMaven.Games.Game

  @settings_steps %{
    "suggestions" => "suggestions",
    "did_you_know" => "did_you_know",
    "first_player" => "first_player",
    "common_mistakes" => "common_mistakes",
    "quiz" => "quiz",
    "teach" => "teach_pitch",
    "score" => "score_categories",
    "turn" => "turn_flow"
  }

  @steps ~w(suggestions categories cheat_sheet setup did_you_know voices first_player
            common_mistakes quiz teach score turn expansion_delta theme symbols)

  @doc "Validate and import every step present in `data`. Returns `{:ok, [step]}`."
  def import(%Game{} = game, data) when is_map(data) do
    steps = Enum.filter(@steps, &Map.has_key?(data, &1))

    with :ok <- expansion_only(steps, game),
         :ok <- validate_all(steps, data),
         :ok <- symbol_tokens_in_book(steps, data, game) do
      Enum.each(steps, &put_step(&1, data[&1], game))
      Readiness.recompute(game)
      {:ok, steps}
    end
  end

  # A delta is only ever composed into a base game's views via its expansion
  # link; on a base game it would be silently dead content.
  # Expansions inherit the base game's palette, so a theme on one is dead too.
  defp expansion_only(steps, game) do
    expansion? = Games.expansion?(game.id)

    cond do
      "expansion_delta" in steps and not expansion? ->
        {:error, {"expansion_delta", :not_an_expansion}}

      "theme" in steps and expansion? ->
        {:error, {"theme", :expansions_inherit_theme}}

      true ->
        :ok
    end
  end

  defp symbol_tokens_in_book(steps, data, game) do
    if "symbols" in steps do
      tokens = Enum.map(data["symbols"], & &1["token"])

      case RuleMaven.Symbols.tokens_in_text(tokens, Games.document_full_text(game)) do
        {_, []} -> :ok
        {_, missing} -> {:error, {"symbols", {:tokens_not_in_book, missing}}}
      end
    else
      :ok
    end
  end

  defp validate_all(steps, data) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case validate(step, data[step]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {step, reason}}}
      end
    end)
  end

  ## Validation — mirrors the LLM parsers' acceptance rules --------------------

  defp validate("suggestions", [_ | _] = cats),
    do: all(cats, &(str?(&1["category"]) and nonempty_strs?(&1["questions"])))

  defp validate("categories", [_ | _] = cats),
    do: all(cats, &(str?(&1["name"]) and str?(&1["description"])))

  defp validate("cheat_sheet", md) when is_binary(md),
    do: if(String.length(md) in 1..10_000, do: :ok, else: {:error, :length})

  defp validate("setup", %{"components" => comps, "setup" => [_ | _] = steps}),
    do:
      if(nonempty_strs?(comps),
        do: all(steps, &(str?(&1["title"]) and str?(&1["detail"]))),
        else: {:error, :components}
      )

  defp validate("did_you_know", facts), do: strs_min(facts, 20)
  defp validate("first_player", picks), do: strs_min(picks, 12)

  defp validate("voices", [_ | _] = voices) when length(voices) <= 12,
    do:
      all(voices, fn v ->
        str?(v["label"]) and str?(v["emoji"]) and str?(v["style"]) and
          String.length(v["style"]) <= 400
      end)

  defp validate("common_mistakes", [_ | _] = ms) when length(ms) <= 8,
    do: all(ms, &(str_min?(&1["wrong"], 12) and str_min?(&1["right"], 12)))

  defp validate("quiz", [_ | _] = qs) when length(qs) <= 20,
    do:
      all(qs, fn q ->
        choices = q["choices"]

        str?(q["q"]) and str?(q["why"]) and nonempty_strs?(choices) and length(choices) >= 2 and
          is_integer(q["answer"]) and q["answer"] in 0..(length(choices) - 1)
      end)

  defp validate("teach", %{} = m),
    do:
      if(
        map_size(m) > 0 and
          Enum.all?(m, fn {k, v} -> k in ~w(goal loop win trap) and str_min?(v, 8) end),
        do: :ok,
        else: {:error, :shape}
      )

  defp validate("score", cats) when is_list(cats) and length(cats) <= 12,
    do: all(cats, &(str?(&1["label"]) and String.length(&1["label"]) <= 40 and str?(&1["hint"])))

  defp validate("turn", [_ | _] = phases) when length(phases) <= 10,
    do:
      all(phases, fn p ->
        actions = p["actions"]

        str?(p["name"]) and is_list(actions) and actions != [] and length(actions) <= 12 and
          Enum.all?(actions, &(str?(&1["label"]) and str?(&1["rule"])))
      end)

  defp validate("expansion_delta", %{} = d) do
    comps = d["components"] || []
    setup = d["setup"] || []
    rules = d["rules"] || []

    cond do
      Map.keys(d) -- ~w(components setup rules) != [] -> {:error, :shape}
      comps == [] and setup == [] and rules == [] -> {:error, :empty}
      not (is_list(comps) and Enum.all?(comps, &str?/1)) -> {:error, :components}
      not (is_list(rules) and Enum.all?(rules, &str?/1)) -> {:error, :rules}
      not is_list(setup) -> {:error, :setup}
      true -> all(setup, &(str?(&1["title"]) and str?(&1["detail"])))
    end
  end

  defp validate("theme", anchors) do
    case ThemePalette.build_sets(anchors) do
      {:ok, _sets} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate("symbols", syms) when is_list(syms) and length(syms) <= 120 do
    tokens = Enum.map(syms, & &1["token"])

    cond do
      length(Enum.uniq(tokens)) != length(tokens) ->
        {:error, :duplicate_tokens}

      true ->
        all(syms, fn s ->
          str?(s["token"]) and String.length(s["token"]) <= 120 and
            (is_nil(s["name"]) or str?(s["name"])) and
            (is_nil(s["aliases"]) or
               (is_list(s["aliases"]) and Enum.all?(s["aliases"], &is_binary/1))) and
            valid_symbol_image?(s)
        end)
    end
  end

  defp validate(_step, _value), do: {:error, :shape}

  defp valid_symbol_image?(%{"image_base64" => b64}) when is_binary(b64),
    do: match?({:ok, _}, Base.decode64(b64, ignore: :whitespace))

  defp valid_symbol_image?(%{"image_path" => path}) when is_binary(path), do: File.regular?(path)
  defp valid_symbol_image?(_), do: true

  defp all(list, fun), do: if(Enum.all?(list, fun), do: :ok, else: {:error, :shape})
  defp strs_min([_ | _] = xs, n), do: all(xs, &str_min?(&1, n))
  defp strs_min(_, _), do: {:error, :shape}
  defp str?(s), do: is_binary(s) and String.trim(s) != ""
  defp str_min?(s, n), do: str?(s) and String.length(s) >= n
  defp nonempty_strs?(xs), do: is_list(xs) and xs != [] and Enum.all?(xs, &str?/1)

  ## Persistence — the same calls the workers make ----------------------------

  defp put_step(step, value, game) when is_map_key(@settings_steps, step),
    do: put!("#{@settings_steps[step]}_#{game.id}", Jason.encode!(value))

  defp put_step("categories", cats, game) do
    Games.replace_game_categories(
      game,
      Enum.map(cats, &%{name: &1["name"], description: &1["description"]})
    )

    Settings.delete("categories_#{game.id}")
  end

  defp put_step("cheat_sheet", md, game) do
    put!("cheat_cancelled_#{game.id}", "false")
    Settings.delete("cheat_error_#{game.id}")
    put!("cheat_content_#{game.id}", md)
    put!("cheat_status_#{game.id}", "done")

    case Games.list_documents(game) do
      [doc | _] -> CheatSheet.save_version(doc.id, md, "compact")
      [] -> :ok
    end
  end

  defp put_step("setup", checklist, game) do
    Settings.delete("setup_error_#{game.id}")
    put!("setup_content_#{game.id}", Jason.encode!(checklist))
    put!("setup_status_#{game.id}", "done")
  end

  # Same keys ExpansionDeltaWorker writes; a non-nil status also stops
  # Readiness.ensure_enrichments from firing the LLM generation.
  defp put_step("expansion_delta", delta, game) do
    Settings.delete("delta_error_#{game.id}")

    put!(
      "delta_content_#{game.id}",
      Jason.encode!(%{
        "components" => delta["components"] || [],
        "setup" => delta["setup"] || [],
        "rules" => delta["rules"] || []
      })
    )

    put!("delta_status_#{game.id}", "done")
  end

  # The key replaces the game's whole key. Images are written first; an
  # unreadable/oversized one fails the import loudly rather than silently
  # dropping the icon. An empty list records "this book has no symbols" so the
  # step reads complete without the LLM worker ever running.
  defp put_step("symbols", syms, game) do
    entries =
      Enum.map(syms, fn s ->
        image =
          case symbol_image_binary(s) do
            nil ->
              nil

            bin ->
              {:ok, rel} = RuleMaven.Symbols.store_image(game.id, bin, s["name"] || s["token"])
              rel
          end

        %{
          token: s["token"],
          name: s["name"],
          meaning: s["meaning"],
          aliases: s["aliases"] || [],
          page: s["page"],
          image_path: image,
          image_note: s["image_note"]
        }
      end)

    {:ok, _} = RuleMaven.Symbols.replace(game.id, entries)
    RuleMaven.Symbols.mark_none(game.id, entries == [])
  end

  # Same write ThemePaletteWorker makes: palette and names together, so the
  # index-aligned palette_sets/1 and name_sets/1 readers stay in step.
  defp put_step("theme", anchors, game) do
    {:ok, sets} = ThemePalette.build_sets(anchors)

    {:ok, _} =
      Games.update_game(game, %{
        theme_palette: %{"sets" => Enum.map(sets, & &1.palette)},
        theme_names: %{"sets" => Enum.map(sets, & &1.names)}
      })
  end

  # Hand-authored, invented personas are trusted (vetted: true): the style string
  # goes straight into the ask prompt without the lazy LLM vet.
  defp put_step("voices", voices, game) do
    Voices.replace_generated(
      game.id,
      voices
      |> Enum.with_index(1)
      |> Enum.map(fn {v, rank} ->
        %{
          slug: slugify(v["label"]),
          label: v["label"],
          emoji: v["emoji"],
          style: v["style"],
          description: v["description"],
          loading_phrases: v["loading_phrases"] || [],
          thanks_phrases: v["thanks_phrases"] || [],
          popularity_rank: rank,
          vetted: true
        }
      end)
    )
  end

  # Settings.put fails silently past the 10k-char cap in the workers; here a
  # failed write is an import error, not a quietly-Pending step.
  defp put!(key, value) do
    case Settings.put(key, value) do
      {:ok, _} -> :ok
      error -> raise "Settings.put #{key} failed: #{inspect(error)}"
    end
  end

  defp symbol_image_binary(%{"image_base64" => b64}) when is_binary(b64),
    do: Base.decode64!(b64, ignore: :whitespace)

  defp symbol_image_binary(%{"image_path" => path}) when is_binary(path), do: File.read!(path)
  defp symbol_image_binary(_), do: nil

  defp slugify(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end
end
