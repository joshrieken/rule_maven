defmodule RuleMaven.Symbols do
  @moduledoc """
  Per-game SYMBOL KEY: what each inline symbol in a rulebook transcription
  means. Transcriptions describe icons neutrally ("[purple hammer symbol]")
  because naming them from the picture is exactly where vision models go
  wrong; the key maps each token to the name and meaning the BOOK gives it
  (its legend / iconography), so the ask prompt — and players, through the
  Symbols table tool — can tell that the purple hammer is the Blacksmith.

  Tokens may stand for a numeric family with `{n}` ("[black triangle: {n}]").
  Every stored token must occur in the game's own rulebook text
  (`tokens_in_text/2`), whoever authored it — Claude's import or the
  in-app SymbolKeyWorker.

  Icons: optional per-symbol crops of rulebook art, stored under the uploads
  root (never `priv/static`) and served only by `SymbolController` while
  `images_enabled?/1` — the global `:symbol_images` kill switch AND the
  per-game toggle — says so.
  """

  import Ecto.Query

  alias RuleMaven.{Audit, Flags, Repo, Settings, Uploads}
  alias RuleMaven.Symbols.Symbol

  @max_image_bytes 512 * 1024

  @doc "A game's symbols in key order."
  def list(game_id) do
    Repo.all(from s in Symbol, where: s.game_id == ^game_id, order_by: [s.position, s.id])
  end

  @doc "Symbols for several games, as `[{game_id, [symbol]}]` in the given order, empty games dropped."
  def list_for_games(game_ids) do
    by_game =
      Repo.all(from s in Symbol, where: s.game_id in ^game_ids, order_by: [s.position, s.id])
      |> Enum.group_by(& &1.game_id)

    for id <- game_ids, syms = Map.get(by_game, id, []), syms != [], do: {id, syms}
  end

  @doc "True when the game has a symbol key."
  def any?(game_id), do: Repo.exists?(from s in Symbol, where: s.game_id == ^game_id)

  @doc """
  The symbol-key step is complete: the game has a key, or its book was
  checked and has no inline symbols (`mark_none/2`). Without the marker an
  icon-free book would sit Pending forever and re-bill the worker.
  """
  def done?(game_id), do: any?(game_id) or Settings.get(none_key(game_id)) == "on"

  @doc "Records (or clears) that the game's book has no inline symbols."
  def mark_none(game_id, true), do: Settings.put(none_key(game_id), "on")
  def mark_none(game_id, false), do: Settings.delete(none_key(game_id))

  defp none_key(game_id), do: "symbols_none_#{game_id}"

  @doc """
  Replaces a game's whole key with `entries` (maps with atom keys: token,
  name, meaning, aliases, page, image_path, image_note). Image files no
  longer referenced are deleted. Returns `{:ok, [symbol]}` or
  `{:error, changeset}`.
  """
  def replace(game_id, entries, source \\ "manual") do
    old_images = image_paths(game_id)

    result =
      Repo.transaction(fn ->
        Repo.delete_all(from s in Symbol, where: s.game_id == ^game_id)

        entries
        |> Enum.with_index()
        |> Enum.map(fn {e, i} ->
          attrs = Map.merge(e, %{game_id: game_id, position: i, source: source})

          case %Symbol{} |> Symbol.changeset(attrs) |> Repo.insert() do
            {:ok, s} -> s
            {:error, cs} -> Repo.rollback(cs)
          end
        end)
      end)

    with {:ok, symbols} <- result do
      kept = MapSet.new(symbols, & &1.image_path)
      for path <- old_images, not MapSet.member?(kept, path), do: delete_file(path)
      {:ok, symbols}
    end
  end

  @doc "Deletes a game's key and its image files."
  def clear(game_id) do
    paths = image_paths(game_id)
    Repo.delete_all(from s in Symbol, where: s.game_id == ^game_id)
    mark_none(game_id, false)
    Enum.each(paths, &delete_file/1)
    :ok
  end

  defp image_paths(game_id) do
    Repo.all(
      from s in Symbol,
        where: s.game_id == ^game_id and not is_nil(s.image_path),
        select: s.image_path
    )
  end

  defp delete_file(rel), do: File.rm(Uploads.resolve(rel))

  # ── Tokens ────────────────────────────────────────────────────────────────

  @doc "Regex matching a token in rulebook text (`{n}` = any number, case-insensitive)."
  def token_regex(token) do
    pattern =
      token
      |> String.split("{n}")
      |> Enum.map_join("\\d+", &Regex.escape/1)

    Regex.compile!(pattern, "iu")
  end

  @doc "Splits tokens into `{found, missing}` against the rulebook text."
  def tokens_in_text(tokens, text) do
    Enum.split_with(tokens, &Regex.match?(token_regex(&1), text))
  end

  # ── Prompt ────────────────────────────────────────────────────────────────

  @doc """
  The SYMBOL KEY block for the answer prompt, covering `game_ids` (base
  first, then expansions), or "" when none has a key. Deterministic for an
  unchanged key, so it can ride inside the cached rulebook prefix.
  """
  def prompt_block(game_ids) do
    case list_for_games(game_ids) do
      [] ->
        ""

      groups ->
        names = game_names(Enum.map(groups, &elem(&1, 0)))

        body =
          Enum.map_join(groups, "\n", fn {gid, syms} ->
            ~s(#{names[gid]}:\n) <> Enum.map_join(syms, "\n", &key_line/1)
          end)

        "=== SYMBOL KEY — what the bracketed symbols in the rulebook text mean, as each book defines them. " <>
          "Use it to match a player's description of an icon (\"the purple hammer\") to the rules; " <>
          "\"{n}\" stands for any number. ===\n" <> body
    end
  end

  defp key_line(%Symbol{} = s) do
    name = if s.name, do: " = #{s.name}", else: ""
    meaning = if s.meaning, do: " — #{s.meaning}", else: ""
    aka = if s.aliases != [], do: " (also: #{Enum.join(s.aliases, ", ")})", else: ""
    page = if s.page, do: " [p. #{s.page}]", else: ""
    "- #{s.token}#{name}#{meaning}#{aka}#{page}"
  end

  defp game_names(ids) do
    Repo.all(from g in RuleMaven.Games.Game, where: g.id in ^ids, select: {g.id, g.name})
    |> Map.new()
  end

  # ── Images ────────────────────────────────────────────────────────────────

  @doc """
  Stores an icon image (PNG/JPEG/WebP, ≤ 512 KB) for a game. Returns
  `{:ok, rel_path}` or `{:error, reason}`.
  """
  def store_image(game_id, binary, name) when is_binary(binary) do
    with {:ok, ext} <- image_ext(binary),
         :ok <-
           if(byte_size(binary) <= @max_image_bytes, do: :ok, else: {:error, :image_too_large}) do
      dir = "uploads/symbols/#{game_id}"
      File.mkdir_p!(Uploads.resolve(dir))

      slug =
        name
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")

      rel = Path.join(dir, "#{System.unique_integer([:positive])}-#{slug}.#{ext}")
      File.write!(Uploads.resolve(rel), binary)
      {:ok, rel}
    end
  end

  defp image_ext(<<0x89, "PNG", _::binary>>), do: {:ok, "png"}
  defp image_ext(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "jpg"}
  defp image_ext(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "webp"}
  defp image_ext(_), do: {:error, :not_an_image}

  @doc "Content type for a stored image path."
  def content_type(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  @doc "Icons are shown for this game: global kill switch on AND not switched off for the game."
  def images_enabled?(game_id) do
    Flags.enabled?(:symbol_images) and Settings.get(images_off_key(game_id)) != "on"
  end

  @doc "Per-game icon switch (the global one is the `:symbol_images` flag). Audited."
  def set_images(game_id, enabled?, actor) do
    if enabled?,
      do: Settings.delete(images_off_key(game_id)),
      else: Settings.put(images_off_key(game_id), "on")

    Audit.log(actor, if(enabled?, do: "symbols.images_on", else: "symbols.images_off"),
      target_type: "game",
      target_id: game_id
    )

    :ok
  end

  @doc "Per-game switch state, ignoring the global flag."
  def game_images_on?(game_id), do: Settings.get(images_off_key(game_id)) != "on"

  defp images_off_key(game_id), do: "symbol_images_off_#{game_id}"
end
