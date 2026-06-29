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

  def get_version(id) do
    Repo.get(RuleMaven.CheatSheet.CheatSheetVersion, id)
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
  Starts durable cheat sheet generation via an Oban job (survives server
  restarts). Seeds the Settings state machine synchronously so the form shows
  "compressing" immediately, then enqueues the worker which fills in the result
  and broadcasts `{:cheat_done, game_id}` on `CheatSheetGenWorker.topic/1`.
  """
  def generate_async(game, level \\ "compact", expansion_ids \\ []) do
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

    if Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      %{game_id: game_id, level: level, expansion_ids: expansion_ids}
      |> RuleMaven.Workers.CheatSheetGenWorker.new()
      |> Oban.insert()
    end

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
  def generate_content(game, level \\ "compact", expansion_ids \\ []) do
    full_text =
      if expansion_ids == [] do
        Games.rulebook_text(game)
      else
        Games.rulebook_text_for_games([game.id | expansion_ids])
      end

    if String.trim(full_text) == "" do
      {:error, "No rulebook text available for #{game.name}"}
    else
      annotated = annotate_pages(full_text)

      with {:ok, compressed} <- compress_text(game.name, annotated, game.id),
           {:ok, content} <- generate_cheat_sheet_content(game.name, compressed, level, game.id) do
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
  defp compress_text(game_name, full_text, game_id) do
    if String.length(full_text) < 12_000 do
      {:ok, full_text}
    else
      system = RuleMaven.Prompts.template("cheat_compress_system")
      prompt = RuleMaven.Prompts.render("cheat_compress", %{rulebook: full_text})

      case RuleMaven.LLM.chat(prompt, game_name,
             operation: "cheat_sheet",
             game_id: game_id,
             system: system,
             max_tokens: 2048
           ) do
        {:ok, compressed} -> {:ok, compressed}
        {:error, _} -> {:ok, String.slice(full_text, 0, 40_000)}
      end
    end
  end

  defp generate_cheat_sheet_content(game_name, full_text, level, game_id) do
    prompt = prompt_for_level(game_name, full_text, level)
    system = RuleMaven.Prompts.template("cheat_generate_system")

    case RuleMaven.LLM.chat(prompt, game_name,
           operation: "cheat_sheet",
           game_id: game_id,
           system: system,
           max_tokens: 2048
         ) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  # Each level maps to its own editable prompt template; an unknown level falls
  # back to the compact reference card (the default).
  defp prompt_for_level(game_name, full_text, level) do
    key =
      case level do
        "ultra" -> "cheat_ultra"
        "full" -> "cheat_full"
        "detailed" -> "cheat_detailed"
        "standard" -> "cheat_standard"
        _ -> "cheat_compact"
      end

    RuleMaven.Prompts.render(key, %{game_name: game_name, rulebook: full_text})
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

  # Render the cheatsheet markdown with MDEx (the same engine the rest of the app
  # uses) instead of the former hand-rolled regex pass. MDEx handles GFM tables,
  # nested/ordered lists, blockquotes, and inline formatting correctly; the
  # wrap_html CSS targets the standard tags MDEx emits (h2/h3/table/blockquote/…),
  # so styling carries over. Falls back to escaped text if rendering fails.
  defp markdown_to_html(md) do
    case MDEx.to_html(md,
           extension: [table: true, strikethrough: true, autolink: true, tasklist: true]
         ) do
      {:ok, html} ->
        html

      {:error, _} ->
        md |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end
end
