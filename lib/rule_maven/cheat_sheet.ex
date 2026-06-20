defmodule RuleMaven.CheatSheet do
  @moduledoc """
  Generates cheat sheet content from rulebook text using the LLM.
  Serves as HTML via browser.
  """

  alias RuleMaven.{Games, Repo, Settings}
  import Ecto.Query

  # ── Cheatsheet version management ──

  @doc """
  Saves a cheatsheet version for a document. Sets it active if first.
  """
  def save_version(document_id, content, level \\ "compact") do
    # If this is the first version, mark it active
    active =
      Repo.aggregate(
        from(v in RuleMaven.CheatSheet.CheatSheetVersion,
          where: v.document_id == ^document_id
        ),
        :count
      ) == 0

    %RuleMaven.CheatSheet.CheatSheetVersion{}
    |> RuleMaven.CheatSheet.CheatSheetVersion.changeset(%{
      document_id: document_id,
      content: content,
      level: level,
      active: active
    })
    |> Repo.insert()
  end

  @doc """
  Returns all versions for a document, newest first.
  """
  def list_versions(document_id) do
    Repo.all(
      from v in RuleMaven.CheatSheet.CheatSheetVersion,
        where: v.document_id == ^document_id,
        order_by: [desc: v.inserted_at]
    )
  end

  @doc """
  Gets the active version for a document, or nil.
  """
  def active_version(document_id) do
    Repo.one(
      from v in RuleMaven.CheatSheet.CheatSheetVersion,
        where: v.document_id == ^document_id and v.active == true
    )
  end

  @doc """
  Gets a specific version by ID.
  """
  def get_version!(id) do
    Repo.get!(RuleMaven.CheatSheet.CheatSheetVersion, id)
  end

  @doc """
  Sets one version as active, deactivates all others for this document.
  """
  def set_active(%RuleMaven.CheatSheet.CheatSheetVersion{} = version) do
    Repo.update_all(
      from(v in RuleMaven.CheatSheet.CheatSheetVersion,
        where: v.document_id == ^version.document_id
      ),
      set: [active: false]
    )

    Repo.update(RuleMaven.CheatSheet.CheatSheetVersion.changeset(version, %{active: true}))
  end

  @doc """
  Deletes a version.
  """
  def delete_version(%RuleMaven.CheatSheet.CheatSheetVersion{} = version) do
    Repo.delete(version)
  end

  @doc """
  Starts async cheat sheet generation in a background Task.
  Stores progress in Settings so it survives page refresh.
  Sends {:cheat_done, game_id} to caller when complete.
  """
  def generate_async(game, caller_pid, level \\ "compact") do
    game_id = game.id
    started = System.system_time(:second)

    Settings.put("cheat_status_#{game_id}", "compressing")
    Settings.put("cheat_content_#{game_id}", nil)
    Settings.put("cheat_error_#{game_id}", nil)
    Settings.put("cheat_started_#{game_id}", started)
    Settings.put("cheat_cancelled_#{game_id}", "false")
    Settings.put("cheat_provider_#{game_id}", RuleMaven.LLM.provider())
    Settings.put("cheat_model_#{game_id}", RuleMaven.LLM.model())
    Settings.put("cheat_level_#{game_id}", level)

    Task.start(fn ->
      result =
        try do
          generate_content(game, level)
        rescue
          e ->
            {:error, "Unexpected error: #{Exception.message(e)}"}
        catch
          :exit, reason ->
            {:error, "Process exited: #{inspect(reason)}"}
        end

      elapsed = System.system_time(:second) - started

      # Don't overwrite if cancelled
      if Settings.get("cheat_cancelled_#{game_id}") == "true" do
        send(caller_pid, {:cheat_done, game_id})
      else
        case result do
          {:ok, content} ->
            Settings.put("cheat_status_#{game_id}", "done")
            Settings.put("cheat_content_#{game_id}", content)

          {:error, reason} ->
            Settings.put("cheat_status_#{game_id}", "error")
            Settings.put("cheat_error_#{game_id}", reason)
        end

        Settings.put("cheat_elapsed_#{game_id}", elapsed)
        send(caller_pid, {:cheat_done, game_id})
      end
    end)

    :ok
  end

  @doc """
  Returns current cheat generation status for a game: nil, "compressing", "done", "error".
  """
  def status(game_id) do
    Settings.get("cheat_status_#{game_id}")
  end

  @doc """
  Returns stored cheat content for a game, or nil.
  """
  def stored_content(game_id) do
    Settings.get("cheat_content_#{game_id}")
  end

  @doc """
  Returns stored cheat error for a game, or nil.
  """
  def stored_error(game_id) do
    Settings.get("cheat_error_#{game_id}")
  end

  @doc """
  Returns stored provider name, or nil.
  """
  def stored_provider(game_id) do
    Settings.get("cheat_provider_#{game_id}")
  end

  @doc """
  Returns stored model name, or nil.
  """
  def stored_model(game_id) do
    Settings.get("cheat_model_#{game_id}")
  end

  @doc """
  Returns stored cheat level, or nil.
  """
  def stored_level(game_id) do
    Settings.get("cheat_level_#{game_id}")
  end

  @doc """
  Returns stored elapsed seconds, or nil.
  """
  def stored_elapsed(game_id) do
    case Settings.get("cheat_elapsed_#{game_id}") do
      nil ->
        nil

      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> nil
        end
    end
  end

  @doc """
  Returns stored cheat started timestamp, or nil.
  """
  def stored_started(game_id) do
    case Settings.get("cheat_started_#{game_id}") do
      nil ->
        nil

      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> nil
        end
    end
  end

  @doc """
  Returns true if generation was cancelled for a game.
  """
  def cancelled?(game_id) do
    Settings.get("cheat_cancelled_#{game_id}") == "true"
  end

  @doc """
  Clears stored cheat state for a game.
  """
  def clear(game_id) do
    Settings.put("cheat_status_#{game_id}", nil)
    Settings.put("cheat_content_#{game_id}", nil)
    Settings.put("cheat_error_#{game_id}", nil)
    Settings.put("cheat_started_#{game_id}", nil)
    Settings.put("cheat_level_#{game_id}", nil)
    Settings.put("cheat_cancelled_#{game_id}", "true")
  end

  @doc """
  Generates cheat sheet markdown content from rulebook text.
  Returns `{:ok, markdown}` or `{:error, reason}`.
  """
  def generate_content(game, level \\ "compact") do
    full_text = Games.rulebook_text(game)

    if String.trim(full_text) == "" do
      {:error, "No rulebook text available for #{game.name}"}
    else
      annotated = annotate_pages(full_text)

      with {:ok, compressed} <- compress_text(game.name, annotated),
           {:ok, content} <- generate_cheat_sheet_content(game.name, compressed, level) do
        {:ok, content}
      end
    end
  end

  # Replace \f page breaks with visible [Page N] markers for LLM citation
  defp annotate_pages(text) do
    pages = String.split(text, "\f")

    if length(pages) <= 1 do
      text
    else
      pages
      |> Enum.with_index(1)
      |> Enum.map(fn {page_text, n} ->
        "[Page #{n}]\n#{String.trim(page_text)}"
      end)
      |> Enum.join("\n\n")
    end
  end

  @doc """
  Wraps cheatsheet markdown in HTML for browser viewing.
  """
  def wrap_html_for_serve(game_name, markdown) do
    {:ok, wrap_html(game_name, markdown)}
  end

  # If text is under ~12k chars, no compression needed.
  # Otherwise, ask LLM to strip flavor/examples, keep only mechanical rules.
  defp compress_text(game_name, full_text) do
    if String.length(full_text) < 12_000 do
      {:ok, full_text}
    else
      system =
        "You are a rulebook compressor. Extract only mechanical rules. Strip ALL flavor, examples, setup narrative, component descriptions. Keep only the rules themselves."

      prompt = """
      Compress this rulebook. Remove: flavor text, lore, examples, component flavor, setup narrative, credits, table of contents, index. Keep: every mechanical rule, number, procedure, turn order, phase structure, scoring, win condition. Output raw rules only, no commentary.

      RULEBOOK:
      #{full_text}
      """

      case RuleMaven.LLM.chat(prompt, game_name, system: system, max_tokens: 2048) do
        {:ok, compressed} -> {:ok, compressed}
        {:error, _} -> {:ok, String.slice(full_text, 0, 40_000)}
      end
    end
  end

  defp generate_cheat_sheet_content(game_name, full_text, level) do
    prompt = prompt_for_level(game_name, full_text, level)
    system = "You are a board game reference writer. Follow the instructions exactly."

    case RuleMaven.LLM.chat(prompt, game_name, system: system, max_tokens: 2048) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_for_level(game_name, full_text, "ultra") do
    """
    Create an ultra-compact cheat sheet for "#{game_name}".
    Max 800 characters. This must fit on one phone screen.

    ## One section: Essentials
    - Every critical number in **bold** (players, hand size, round count, points)
    - Turn flow as one compact line: e.g. "1) Draw 2) Play 3) Discard down to 7"
    - 3-5 easily-forgotten rules and edge cases
    - Setup: one line. Scoring: one line.
    - No section headers. No page citations. No fluff.
    - Use `> ` blockquote for the one most-forgotten rule.

    RULEBOOK:
    #{full_text}
    """
  end

  defp prompt_for_level(game_name, full_text, "full") do
    """
    Create a complete cheat sheet for "#{game_name}".
    Output clean markdown with ## and ### headers. Use `> ` blockquote for
    critical rules and easily-forgotten edge cases.

    ## Sections:
    ### Essentials & Easy to Forget
    Rules players most often miss. One line each. Numbers in **bold**. [p.N]

    ### Numbers at a Glance
    Table: every number in the game. [p.N]

    ### Turn Structure
    Each phase in order. [p.N]

    ### Setup
    Components, starting state, first player. [p.N]

    ### Key Rules
    All remaining important rules. [p.N]

    ### Scoring
    Win condition, triggers, tiebreakers. [p.N]

    **Rules:**
    - Every line gets [p.N] citation.
    - Be thorough. Include everything.

    RULEBOOK:
    #{full_text}
    """
  end

  defp prompt_for_level(game_name, full_text, "detailed") do
    """
    Create a detailed cheat sheet for "#{game_name}".
    Aim for ~4000 characters. Output clean markdown with ## and ### headers.
    Use `> ` blockquote for standout rules and important edge cases.

    ## Sections:
    ### Essentials
    Rules players most often miss. One line each. Bold numbers.

    ### Numbers
    Table: key numbers in the game.

    ### Turn Structure
    Each phase in order. Brief detail per phase.

    ### Setup
    Components, starting state, first player.

    ### Key Rules
    Important rules with brief explanations.

    ### Scoring
    Win condition, triggers, tiebreakers.

    **Rules:**
    - Include explanations where helpful, not just one-liners.
    - Use [p.N] for important rules.

    RULEBOOK:
    #{full_text}
    """
  end

  defp prompt_for_level(game_name, full_text, "standard") do
    """
    Create a standard cheat sheet for "#{game_name}".
    Aim for ~2500 characters. Output clean markdown with ## and ### headers.
    Use `> ` blockquote for the most easily-forgotten or critical rules.

    ## Sections:
    ### Essentials
    Rules players most often miss. Brief. Bold numbers.

    ### Numbers
    Table: key numbers.

    ### Turn Structure
    Each phase in order.

    ### Setup + Scoring
    Combined: starting state, first player, win condition.

    ### Key Rules
    Remaining important rules, concise.

    **Rules:**
    - More detail than compact, less than full.
    - Use [p.N] where helpful.

    RULEBOOK:
    #{full_text}
    """
  end

  defp prompt_for_level(game_name, full_text, _level) do
    """
    Create a dense, single-column cheat sheet for "#{game_name}".
    Aim for ~1500 characters max. This is a phone-sized reference card.
    Output clean markdown with proper ## and ### headers.

    ## Section order:

    ### Essentials
    Every critical number, limit, and easily-forgotten rule. Combine related
    rules into single bullets. Group by topic (setup, turns, scoring) rather
    than separate sections. Bold numbers. No page citations unless the rule
    is non-obvious. Use `> ` blockquote for standout forgotten rules.

    ### Numbers
    Compact table: player count, hand size, round count, point thresholds,
    costs — only the numbers players actually need to reference.

    ### Turn Flow
    One line per phase. No fluff.

    **Rules:**
    - Be as dense as you can without losing clarity.
    - Combine related rules. Don't give each rule its own bullet.
    - Omit obvious rules.
    - No introductions, no flavor, no examples.

    RULEBOOK:
    #{full_text}
    """
  end

  defp wrap_html(game_name, content) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{escape_html(game_name)} — Cheat Sheet</title>
    <style>
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.5;
        color: #1a1a2e;
        background: #f8f9fb;
        padding: 24px 20px 60px;
        max-width: 780px;
        margin: 0 auto;
      }
      .sheet {
        background: #fff;
        border-radius: 12px;
        box-shadow: 0 1px 3px rgba(0,0,0,0.06), 0 4px 12px rgba(0,0,0,0.04);
        padding: 32px 36px;
      }
      .sheet-header {
        border-bottom: 3px solid #2563eb;
        padding-bottom: 12px;
        margin-bottom: 24px;
      }
      .sheet-header h1 {
        font-size: 22px;
        font-weight: 700;
        color: #111827;
        letter-spacing: -0.3px;
      }
      .sheet-header .subtitle {
        font-size: 12px;
        color: #6b7280;
        margin-top: 4px;
        font-weight: 500;
        text-transform: uppercase;
        letter-spacing: 0.5px;
      }
      h2 {
        font-size: 16px;
        font-weight: 700;
        color: #1e40af;
        margin: 28px 0 10px 0;
        padding: 6px 0 6px 12px;
        border-left: 4px solid #2563eb;
        background: #eff6ff;
        border-radius: 0 6px 6px 0;
      }
      h2:first-of-type { margin-top: 0; }
      h3 {
        font-size: 14px;
        font-weight: 600;
        color: #374151;
        margin: 18px 0 6px 0;
        padding-left: 8px;
        border-left: 3px solid #93c5fd;
      }
      p { margin: 6px 0; color: #374151; }
      strong { color: #111827; }
      ul, ol { margin: 6px 0 6px 20px; }
      li { margin-bottom: 3px; color: #374151; }
      li:last-child { margin-bottom: 0; }
      blockquote {
        margin: 12px 0;
        padding: 10px 14px;
        background: #fffbeb;
        border-left: 4px solid #f59e0b;
        border-radius: 0 6px 6px 0;
        font-size: 13px;
        color: #92400e;
      }
      blockquote p { color: inherit; margin: 0; }
      table {
        border-collapse: collapse;
        width: 100%;
        margin: 12px 0;
        font-size: 13px;
        border-radius: 8px;
        overflow: hidden;
        box-shadow: 0 0 0 1px #e5e7eb;
      }
      thead { background: #f3f4f6; }
      th {
        padding: 9px 12px;
        text-align: left;
        font-weight: 600;
        color: #374151;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.5px;
        border-bottom: 2px solid #d1d5db;
      }
      td {
        padding: 8px 12px;
        border-bottom: 1px solid #f3f4f6;
        color: #4b5563;
      }
      tr:last-child td { border-bottom: none; }
      tbody tr:nth-child(even) { background: #f9fafb; }
      code {
        background: #f3f4f6;
        padding: 1px 5px;
        border-radius: 3px;
        font-size: 12px;
        font-family: "SF Mono", Monaco, "Cascadia Code", monospace;
        color: #d97706;
      }
      .footer {
        margin-top: 32px;
        padding-top: 12px;
        border-top: 1px solid #e5e7eb;
        font-size: 11px;
        color: #9ca3af;
        text-align: center;
      }

      @media (max-width: 600px) {
        body { padding: 12px 8px 40px; }
        .sheet { padding: 20px 16px; border-radius: 8px; }
        h2 { font-size: 15px; }
        table { font-size: 11px; }
        th, td { padding: 6px 8px; }
      }
      @media print {
        body { background: #fff; padding: 0; font-size: 11px; }
        .sheet { box-shadow: none; border-radius: 0; padding: 16px 0; }
        h2 { font-size: 13px; background: none; border-left: 2px solid #333; padding-left: 8px; }
        table { font-size: 10px; box-shadow: none; border: 1px solid #ccc; }
        th, td { padding: 4px 6px; }
      }
    </style>
    </head>
    <body>
    <div class="sheet">
      <div class="sheet-header">
        <h1>#{escape_html(game_name)}</h1>
        <div class="subtitle">Rules Reference</div>
      </div>
      #{markdown_to_html(content)}
    </div>
    </body>
    </html>
    """

    html
  end

  defp escape_html(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp markdown_to_html(md) do
    md
    |> convert_tables()
    |> String.replace(~r/^### (.+)$/m, "<h3>\\1</h3>")
    |> String.replace(~r/^## (.+)$/m, "<h2>\\1</h2>")
    |> String.replace(~r/^# (.+)$/m, "<h1>\\1</h1>")
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\*(.+?)\*/, "<em>\\1</em>")
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/^> (.+)$/m, "<blockquote><p>\\1</p></blockquote>")
    |> String.replace(~r/^- (.+)$/m, "<li>\\1</li>")
    |> String.replace(~r/^\d+\.\s+(.+)$/m, "<li>\\1</li>")
    |> wrap_lists()
    |> String.replace(~r/\n{2,}/, "</p>\n<p>")
    |> then(&"<p>#{&1}</p>")
    |> String.replace(~r/\n/, "<br>\n")
    |> String.replace(~r{<p>\s*</p>}, "")
    |> String.replace(~r{<br>\s*<br>}, "<br>")
  end

  defp convert_tables(md) do
    lines = String.split(md, "\n")

    {result, _state} =
      Enum.reduce(lines, {[], :none}, fn line, {acc, state} ->
        trimmed = String.trim(line)

        cond do
          String.match?(trimmed, ~r/^\|[-:\s|]+\|$/) ->
            {["</thead><tbody>" | acc], :tbody}

          String.match?(trimmed, ~r/^\|.+\|$/) ->
            case state do
              :none ->
                cells = parse_table_row(trimmed)

                row =
                  "<thead><tr>#{Enum.map_join(cells, "", &"<th>#{&1}</th>")}</tr></thead>"

                {[row | acc], :thead}

              _ ->
                cells = parse_table_row(trimmed)
                row = "<tr>#{Enum.map_join(cells, "", &"<td>#{&1}</td>")}</tr>"
                {[row | acc], :tbody}
            end

          state in [:thead, :tbody] ->
            {["</tbody></table>", line | acc], :none}

          true ->
            {[line | acc], :none}
        end
      end)

    # Close trailing table if last line was a table row
    {result, _} =
      case List.first(result) do
        nil ->
          {result, :none}

        line ->
          if String.contains?(line, "<tr>") and
               not String.contains?(line, "</table>") do
            {[line <> "</tbody></table>" | tl(result)], :none}
          else
            {result, :none}
          end
      end

    result
    |> Enum.reverse()
    |> Enum.map_join("\n", fn
      "<thead>" <> _ = line -> "<table>\n#{line}"
      line -> line
    end)
  end

  defp parse_table_row(line) do
    line
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp wrap_lists(html) do
    html
    |> String.replace(~r/((?:^<li>.*<\/li>\n?)+)/m, "<ul>\n\\1</ul>\n")
  end
end
