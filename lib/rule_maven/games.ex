defmodule RuleMaven.Games do
  @moduledoc """
  The Games context.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo

  alias RuleMaven.Games.Game
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Games.QuestionVote
  alias RuleMaven.Games.QuestionFlag
  alias RuleMaven.Games.GameCategory
  alias RuleMaven.Games.QuestionCategoryTag
  alias RuleMaven.Games.Document
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Games.UserCollection
  alias RuleMaven.Games.UserFavorite
  alias RuleMaven.Games.AnswerFavorite
  alias RuleMaven.Games.SupportRequest
  alias RuleMaven.Games.ExpansionLink
  alias RuleMaven.Games.ExpansionSelection
  alias Oban

  NimbleCSV.define(RuleMaven.Games.RankCSV, separator: ",", escape: "\"")

  # ── Games ──

  def list_games, do: Repo.all(Game)

  def count_games, do: Repo.aggregate(Game, :count)

  # ── DMCA takedowns ──

  @doc "True while a game is under a DMCA takedown (hidden + asks blocked)."
  def taken_down?(%Game{} = game), do: Game.taken_down?(game)

  @doc """
  Takes a game down: stamps `taken_down_at` now and records the reason +
  complainant. Hides it from listings and blocks new asks. Reversible.
  """
  def take_down_game(%Game{} = game, reason, complainant) do
    game
    |> Ecto.Changeset.change(
      taken_down_at: DateTime.utc_now() |> DateTime.truncate(:second),
      takedown_reason: reason,
      takedown_complainant: complainant
    )
    |> Repo.update()
  end

  @doc "Restores a taken-down game, clearing the takedown record."
  def restore_game(%Game{} = game) do
    game
    |> Ecto.Changeset.change(
      taken_down_at: nil,
      takedown_reason: nil,
      takedown_complainant: nil
    )
    |> Repo.update()
  end

  @doc "Games currently under takedown, most recent first."
  def list_taken_down do
    Repo.all(
      from g in Game, where: not is_nil(g.taken_down_at), order_by: [desc: g.taken_down_at]
    )
  end

  def list_games_with_documents do
    # Base games + expansions that have published documents.
    # Returns base games sorted by name.
    base_ids =
      (from g in Game,
         join: d in Document,
         on: d.game_id == g.id,
         where: d.status == "published",
         where: is_nil(g.taken_down_at),
         distinct: true,
         select: g.id
      )
      |> not_expansion()
      |> Repo.all()

    Repo.all(from g in Game, where: g.id in ^base_ids)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  Base games that are fully **playable** — the new catalog "Playable" view.
  Reads the denormalized `playable` flag (RAG-ready + reviewed, maintained by
  `RuleMaven.Readiness`) so this stays a single indexed scan on a large catalog,
  no per-row document join.
  """
  def list_playable_games do
    (from g in Game,
       where: g.playable == true,
       where: is_nil(g.taken_down_at)
    )
    |> not_expansion()
    |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  Base games still missing their full BGG data (admin "Needs Pull" view): a
  `bgg_id` present but no cached `bgg_data` yet. DB-paged via `limit` because the
  rank dump can leave a very large number of un-enriched catalog rows. Ordered by
  BGG rank (ranked games first) then name.
  """
  def list_games_needing_bgg(limit \\ 20) do
    (from g in Game,
       where: not is_nil(g.bgg_id),
       where: is_nil(g.bgg_data),
       order_by: [asc_nulls_last: g.bgg_rank, asc: g.name],
       limit: ^limit
    )
    |> not_expansion()
    |> Repo.all()
  end

  @doc """
  Base games that have at least one support request, most-requested first (admin
  "Requested" view). Bounded set, returned in full.
  """
  def list_requested_games do
    (from g in Game,
       join: r in SupportRequest,
       on: r.game_id == g.id,
       group_by: [g.id],
       order_by: [desc: count(r.id), asc: g.name]
    )
    |> not_expansion()
    |> Repo.all()
  end

  def list_base_games do
    (from g in Game) |> not_expansion() |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  # "Is a base game" filter: not linked as an expansion of anything.
  defp not_expansion(query) do
    where(query, [g], g.id not in subquery(from l in ExpansionLink, select: l.expansion_id))
  end

  def expansions_for(%Game{} = game) do
    Repo.all(
      from g in Game,
        join: l in ExpansionLink,
        on: l.expansion_id == g.id,
        where: l.base_game_id == ^game.id,
        select: g
    )
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "Link an expansion to a base game. Idempotent (unique pair, conflict ignored)."
  def link_expansion(expansion_id, base_game_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      ExpansionLink,
      [%{expansion_id: expansion_id, base_game_id: base_game_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: [:expansion_id, :base_game_id]
    )

    :ok
  end

  @doc "Remove one expansion/base pair link."
  def unlink_expansion(expansion_id, base_game_id) do
    Repo.delete_all(
      from l in ExpansionLink,
        where: l.expansion_id == ^expansion_id and l.base_game_id == ^base_game_id
    )

    :ok
  end

  @doc "Ids of every base game this expansion is linked to."
  def base_ids_for(game_id) do
    Repo.all(from l in ExpansionLink, where: l.expansion_id == ^game_id, select: l.base_game_id)
  end

  @doc "True when the game is linked as an expansion of at least one base."
  def expansion?(game_id) do
    Repo.exists?(from l in ExpansionLink, where: l.expansion_id == ^game_id)
  end

  @doc "Map of game_id => document count for the given ids (one query)."
  def document_counts(game_ids) do
    Repo.all(
      from d in Document,
        where: d.game_id in ^game_ids,
        group_by: d.game_id,
        select: {d.game_id, count(d.id)}
    )
    |> Map.new()
  end

  @doc "Map of base game_id => expansion count for the given ids (one query)."
  def expansion_counts(game_ids) do
    Repo.all(
      from l in ExpansionLink,
        where: l.base_game_id in ^game_ids,
        group_by: l.base_game_id,
        select: {l.base_game_id, count(l.expansion_id)}
    )
    |> Map.new()
  end

  @doc """
  Map of base game_id => count of its expansions still missing BGG data
  (a `bgg_id` present but no cached `bgg_data`). Drives whether to show the
  admin "Pull expansions" button.
  """
  def expansion_pull_counts(game_ids) do
    Repo.all(
      from l in ExpansionLink,
        join: g in Game,
        on: g.id == l.expansion_id,
        where: l.base_game_id in ^game_ids,
        where: not is_nil(g.bgg_id) and is_nil(g.bgg_data),
        group_by: l.base_game_id,
        select: {l.base_game_id, count(l.expansion_id)}
    )
    |> Map.new()
  end

  @doc "Map of base game_id => count of expansions that have published documents."
  def expansion_with_doc_counts(game_ids) do
    Repo.all(
      from l in ExpansionLink,
        join: d in Document,
        on: d.game_id == l.expansion_id and d.status == "published",
        where: l.base_game_id in ^game_ids,
        group_by: l.base_game_id,
        select: {l.base_game_id, count(l.expansion_id, :distinct)}
    )
    |> Map.new()
  end

  def expansions_with_documents(%Game{} = base_game) do
    Repo.all(
      from g in Game,
        join: l in ExpansionLink,
        on: l.expansion_id == g.id,
        join: d in Document,
        on: d.game_id == g.id,
        where: l.base_game_id == ^base_game.id and d.status == "published",
        distinct: true,
        select: g
    )
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "All base games this expansion is linked to, name-sorted ([] for base games)."
  def base_games_for(%Game{} = game) do
    Repo.all(
      from g in Game,
        join: l in ExpansionLink,
        on: l.base_game_id == g.id,
        where: l.expansion_id == ^game.id,
        select: g
    )
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "First linked base game (legacy single-parent shape), nil for base games."
  def base_game_for(%Game{} = game), do: game |> base_games_for() |> List.first()

  ## Expansion selection (per user, per base game) -----------------------------

  @doc """
  Remember the expansion set a user plays `base_game_id` with. Upsert; stores
  the set sorted. `[]` is a meaningful "base only" choice (distinct from no
  row, which means "never chosen" and lets the collection-derived default
  apply).
  """
  def put_expansion_selection(user_id, base_game_id, expansion_ids) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      ExpansionSelection,
      [
        %{
          user_id: user_id,
          game_id: base_game_id,
          expansion_ids: Enum.sort(expansion_ids),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:expansion_ids, :updated_at]},
      conflict_target: [:user_id, :game_id]
    )

    :ok
  end

  @doc "The user's stored expansion set for a base game, or nil when never chosen."
  def get_expansion_selection(user_id, base_game_id) do
    Repo.one(
      from s in ExpansionSelection,
        where: s.user_id == ^user_id and s.game_id == ^base_game_id,
        select: s.expansion_ids
    )
  end

  @doc """
  The expansion set to preselect for a user on a base game's page: their
  explicit stored choice if any, else the expansions in their collection.
  Always filtered to expansions that actually have published documents (a
  stored id whose docs were unpublished, or an owned expansion with no
  rulebook, silently drops out), sorted ascending.
  """
  def effective_expansion_ids(user_id, %Game{} = base_game) do
    available = base_game |> expansions_with_documents() |> MapSet.new(& &1.id)

    chosen =
      case get_expansion_selection(user_id, base_game.id) do
        nil ->
          Repo.all(
            from uc in UserCollection,
              where: uc.user_id == ^user_id and uc.game_id in ^MapSet.to_list(available),
              select: uc.game_id
          )

        ids ->
          ids
      end

    chosen |> Enum.filter(&MapSet.member?(available, &1)) |> Enum.sort()
  end

  def get_game!(id), do: Repo.get!(Game, id)

  def get_game(id), do: Repo.get(Game, id)

  @doc "Fetch a game by its public URL token (raises NoResults on a bad/unknown token)."
  def get_game_by_token!(token) do
    case RuleMaven.Hashid.decode(token) do
      {:ok, id} -> Repo.get!(Game, id)
      :error -> raise Ecto.NoResultsError, queryable: Game
    end
  end

  @doc "Fetch a game by its public URL token; nil on a bad/unknown token."
  def get_game_by_token(token) do
    case RuleMaven.Hashid.decode(token) do
      {:ok, id} -> Repo.get(Game, id)
      :error -> nil
    end
  end

  def get_game_by_bgg_id(bgg_id) when is_integer(bgg_id), do: Repo.get_by(Game, bgg_id: bgg_id)

  def create_game(attrs) do
    %Game{}
    |> Game.changeset(attrs)
    |> Repo.insert()
  end

  def update_game(%Game{} = game, attrs) do
    game
    |> Game.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a game and everything under it. Goes through `delete_document/1` for
  each source (rather than a bare `Repo.delete_all(Document)`) so stored
  files are removed from disk, in-flight cleanup/cheatsheet jobs are
  cancelled, and per-game generation-state Settings are cleared — the same
  cleanup `reset_preparation/1` relies on. The document deletions, question
  log wipe, and game delete run in one transaction; file removal and job
  cancellation are side effects of `delete_document/1` that happen as we go
  and are not themselves transactional (a mid-transaction failure after some
  files are already removed would not restore them — acceptable for a
  destructive admin action, and no worse than the non-transactional
  `reset_preparation/1` this mirrors).
  """
  def delete_game(%Game{} = game) do
    Repo.transaction(fn ->
      # delete_document/1's own {:error, _} results are discarded here (same
      # as reset_preparation/1) — a failed per-doc delete doesn't abort the
      # loop; if it leaves the doc row behind, the transaction still surfaces
      # a failure when the final Repo.delete(game) hits the FK constraint.
      Enum.each(list_documents(game), &delete_document/1)
      Repo.delete_all(from q in QuestionLog, where: q.game_id == ^game.id)

      case Repo.delete(game) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Deletes every game. Same rationale as `delete_game/1`: documents are removed
  via `delete_document/1` so files/jobs/settings are cleaned up, not just the
  DB rows. Returns `{count, nil}` on success (matching `Repo.delete_all/2`'s
  shape, since callers pattern-match on it).
  """
  def delete_all_games do
    # delete_document/1's own {:error, _} results are discarded here (same as
    # reset_preparation/1 and delete_game/1) — a failed per-doc delete doesn't
    # abort the loop; nothing calls Repo.rollback in this function, so a
    # genuine DB-level failure (e.g. an unexpected constraint violation) is
    # left to raise and crash the transaction rather than silently returning a
    # dishonest `{:error, _}` tuple callers would render as "Cleared error
    # game(s)".
    {:ok, count} =
      Repo.transaction(fn ->
        Document |> Repo.all() |> Enum.each(&delete_document/1)
        Repo.delete_all(QuestionLog)
        {count, _} = Repo.delete_all(Game)
        count
      end)

    {count, nil}
  end

  def change_game(%Game{} = game, attrs \\ %{}) do
    Game.changeset(game, attrs)
  end

  @doc """
  True once a game's BGG detail pull has populated the enriched fields. Catalog
  import only sets name/year/rank, so these stay nil until a BGG sync
  (refresh_bgg → BggEnrichWorker) runs. Gates the editor and the Prepare links.
  """
  def bgg_synced?(%{image_url: img, min_players: mn, playing_time: pt}) do
    not is_nil(img) or not is_nil(mn) or not is_nil(pt)
  end

  def bgg_synced?(_), do: false

  # ── Catalog import (BGG rank dump) ──

  @doc """
  Bulk-upserts BGG's full game catalog from the rank-dump CSV binary.

  Columns: id,name,yearpublished,rank,bayesaverage,average,usersrated,is_expansion,...
  Upserts by `bgg_id`, replacing only catalog fields so lazily-enriched data
  (image, players, playing_time) on existing rows is preserved. Idempotent.

  Returns the number of rows processed.
  """
  def import_rank_dump(csv_binary) when is_binary(csv_binary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    csv_binary
    |> RuleMaven.Games.RankCSV.parse_string(skip_headers: true)
    |> Stream.map(&dump_row_to_attrs(&1, now))
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(2000)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} =
        Repo.insert_all(Game, chunk,
          on_conflict: {:replace, [:name, :year_published, :bgg_rank, :updated_at]},
          conflict_target: :bgg_id
        )

      acc + count
    end)
  end

  defp dump_row_to_attrs([id, name, year | rest], now) do
    rank = rest |> List.first() |> parse_dump_int()

    with {bgg_id, _} when bgg_id > 0 <- Integer.parse(to_string(id)),
         name when name != "" <- String.trim(to_string(name)) do
      %{
        bgg_id: bgg_id,
        name: name,
        year_published: parse_dump_int(year),
        bgg_rank: rank,
        category: "board_game",
        inserted_at: now,
        updated_at: now
      }
    else
      _ -> nil
    end
  end

  defp dump_row_to_attrs(_, _now), do: nil

  # Dump uses "0" for unranked / missing — treat as nil.
  defp parse_dump_int(v) do
    case Integer.parse(to_string(v)) do
      {0, _} -> nil
      {n, _} -> n
      :error -> nil
    end
  end

  @doc """
  DB-backed catalog search for browsing the (large) global catalog.

  Opts: `:category`, `:limit` (default 50). Orders by popularity
  (`bgg_rank` ascending, nulls last) then name.
  """
  def search_catalog(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    category = Keyword.get(opts, :category)
    term = "%#{String.trim(query || "")}%"

    base =
      from g in Game,
        where: ilike(g.name, ^term),
        order_by: [asc_nulls_last: g.bgg_rank, asc: g.name],
        limit: ^limit

    base
    |> not_expansion()
    |> maybe_category(category)
    |> Repo.all()
  end

  defp maybe_category(query, nil), do: query
  defp maybe_category(query, ""), do: query
  defp maybe_category(query, category), do: from(g in query, where: g.category == ^category)

  # ── User collections ──

  def add_to_collection(user_id, game_id) when is_integer(user_id) and is_integer(game_id) do
    %UserCollection{}
    |> UserCollection.changeset(%{user_id: user_id, game_id: game_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :game_id])
  end

  def remove_from_collection(user_id, game_id) when is_integer(user_id) and is_integer(game_id) do
    Repo.delete_all(
      from uc in UserCollection, where: uc.user_id == ^user_id and uc.game_id == ^game_id
    )
  end

  @doc "Base games in a user's collection, sorted by name."
  def list_collection(user_id) when is_integer(user_id) do
    (from g in Game,
       join: uc in UserCollection,
       on: uc.game_id == g.id,
       where: uc.user_id == ^user_id
    )
    |> not_expansion()
    |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "MapSet of game ids in a user's collection (for membership checks)."
  def collection_game_ids(user_id) when is_integer(user_id) do
    Repo.all(from uc in UserCollection, where: uc.user_id == ^user_id, select: uc.game_id)
    |> MapSet.new()
  end

  @doc "MapSet of BGG ids in a user's collection (for matching BGG import results)."
  def collection_bgg_ids(user_id) when is_integer(user_id) do
    Repo.all(
      from uc in UserCollection,
        join: g in Game,
        on: g.id == uc.game_id,
        where: uc.user_id == ^user_id and not is_nil(g.bgg_id),
        select: g.bgg_id
    )
    |> MapSet.new()
  end

  # ── User favorites ──

  def add_favorite(user_id, game_id) when is_integer(user_id) and is_integer(game_id) do
    %UserFavorite{}
    |> UserFavorite.changeset(%{user_id: user_id, game_id: game_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :game_id])
  end

  def remove_favorite(user_id, game_id) when is_integer(user_id) and is_integer(game_id) do
    Repo.delete_all(
      from uf in UserFavorite, where: uf.user_id == ^user_id and uf.game_id == ^game_id
    )
  end

  @doc "Base games a user has favorited, sorted by name."
  def list_favorites(user_id) when is_integer(user_id) do
    (from g in Game,
       join: uf in UserFavorite,
       on: uf.game_id == g.id,
       where: uf.user_id == ^user_id
    )
    |> not_expansion()
    |> Repo.all()
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "MapSet of game ids a user has favorited (for membership checks)."
  def favorite_game_ids(user_id) when is_integer(user_id) do
    Repo.all(from uf in UserFavorite, where: uf.user_id == ^user_id, select: uf.game_id)
    |> MapSet.new()
  end

  # ── Support requests ──

  @doc "Record a user's request to support a game (deduped per user/game)."
  def request_support(user_id, game_id) when is_integer(user_id) and is_integer(game_id) do
    %SupportRequest{}
    |> SupportRequest.changeset(%{user_id: user_id, game_id: game_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :game_id])
  end

  @doc "MapSet of game ids a user has requested support for (for button state)."
  def requested_game_ids(user_id) when is_integer(user_id) do
    Repo.all(from r in SupportRequest, where: r.user_id == ^user_id, select: r.game_id)
    |> MapSet.new()
  end

  @doc """
  Games with at least one support request, with the request count and most
  recent request time, sorted by count desc. For the admin demand view.
  """
  def list_support_requests do
    Repo.all(
      from r in SupportRequest,
        join: g in Game,
        on: g.id == r.game_id,
        group_by: [g.id],
        order_by: [desc: count(r.id), desc: max(r.inserted_at)],
        select: %{game: g, count: count(r.id), last_requested_at: max(r.inserted_at)}
    )
  end

  # ── Documents ──

  def list_documents(%Game{} = game) do
    Repo.all(from d in Document, where: d.game_id == ^game.id)
  end

  def create_document(attrs) do
    attrs = derive_pages(attrs)

    # Content-hash idempotency: a retried DownloadWorker attempt (or an identical
    # re-upload) re-ingests the same file. If a source with this content already
    # exists on the game, return it instead of inserting a duplicate — otherwise a
    # single upload that retries lands as two rulebooks (and doubles the page
    # count in the review banner). No hash (pasted/legacy sources) → never deduped.
    case existing_document_by_hash(attrs) do
      %Document{} = existing ->
        {:ok, existing}

      nil ->
        insert_document(attrs)
    end
  end

  defp existing_document_by_hash(attrs) do
    hash = Map.get(attrs, :file_hash) || Map.get(attrs, "file_hash")
    game_id = Map.get(attrs, :game_id) || Map.get(attrs, "game_id")

    if is_binary(hash) and hash != "" and game_id do
      Repo.one(
        from d in Document,
          where: d.game_id == ^game_id and d.file_hash == ^hash,
          limit: 1
      )
    end
  end

  defp insert_document(attrs) do
    # A source saved before extraction carries no page text. It can't be chunked,
    # cheat-sheeted, or auto-published yet — those wait for ExtractWorker to fill
    # the pages (extraction runs on demand from the prepare page). Detect it by
    # the absence of real full_text.
    extracted? = is_binary(attrs[:full_text]) and String.trim(attrs[:full_text]) != ""

    # Auto-publish if quality looks good (only an extracted source can qualify).
    status =
      if extracted? and RuleMaven.Settings.get("auto_approve_documents") != "false" and
           quality_ok?(attrs[:full_text] || "") do
        "published"
      else
        "pending_review"
      end

    result =
      %Document{}
      |> Document.changeset(Map.put(attrs, :status, status))
      |> Repo.insert()

    case result do
      {:ok, doc} when not extracted? ->
        # Save-only: no text to chunk/summarize and nothing to invalidate (this
        # source contributes no answers until it's extracted).
        {:ok, doc}

      {:ok, doc} ->
        chunk_document(doc)
        # A new/corrected rulebook can make previously cached answers stale.
        invalidate_pool(doc.game_id)

        # Enqueue cheatsheet generation (skip in test)
        unless testing?() do
          %{document_id: doc.id}
          |> RuleMaven.Workers.CheatSheetWorker.new()
          |> Oban.insert()
        end

        {:ok, doc}

      error ->
        error
    end
  end

  defp quality_ok?(text) do
    stripped = String.trim(text)
    words = String.split(stripped, ~r/\s+/, trim: true)
    total = length(words)

    cond do
      # Too short = extraction junk or a near-empty page.
      String.length(stripped) < 500 ->
        false

      # A real rulebook has many words; a few labels/numbers don't qualify.
      total < 100 ->
        false

      true ->
        # "Prose" words: >= 3 chars, contain a vowel, and are *mostly* letters
        # (rejects "1.2.3", "[12]", component counts, and OCR symbol soup that
        # the old vowel-only check happily passed).
        prose =
          Enum.count(words, fn w ->
            lw = String.downcase(w)
            letters = lw |> String.replace(~r/[^a-z]/, "") |> String.length()

            String.length(w) >= 3 and String.match?(lw, ~r/[aeiou]/) and
              letters >= String.length(lw) * 0.6
          end)

        # Sentence punctuation density guards against table/label dumps that are
        # word-rich but have no real prose structure.
        sentences = length(Regex.scan(~r/[.!?]/, stripped))

        prose / total >= 0.5 and sentences >= 5
    end
  end

  defp testing? do
    Application.get_env(:rule_maven, Oban)[:testing] == :manual
  end

  def get_document!(id), do: Repo.get!(Document, id)

  @doc "Fetches a document by id, returning nil when missing or the id is invalid."
  def get_document(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> Repo.get(Document, int_id)
      _ -> nil
    end
  end

  @doc """
  Re-run the upload-time auto-publish quality check on a `pending_review` doc.

  The insert-time check in `insert_document/1` can only pass for a source that
  already carries extracted text; a source saved first and extracted later
  (`ExtractWorker`) would otherwise stay `pending_review` forever — invisible to
  retrieval even after the game goes playable, so answers ran against an empty
  rulebook. Respects the same `auto_approve_documents` kill switch; docs in any
  other status (published, rejected) are left untouched.
  """
  def maybe_auto_publish(%Document{status: "pending_review"} = doc) do
    if RuleMaven.Settings.get("auto_approve_documents") != "false" and
         quality_ok?(doc.full_text || "") do
      approve_document(doc)
    else
      {:ok, doc}
    end
  end

  def maybe_auto_publish(%Document{} = doc), do: {:ok, doc}

  @doc """
  Admin manual approval: publish a `pending_review` document, record who/when,
  and (re)enqueue embedding generation. The embed enqueue heals docs whose
  upload-time embed job failed or never ran — `EmbedChunksWorker` only touches
  chunks whose `embedding` is still nil, so it's a safe no-op once embedded.
  Without this, an approved-but-unembedded doc would silently serve answers from
  the whole-rulebook full_text fallback forever.
  """
  def approve_document(%Document{} = doc, approver \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      update_document(doc, %{
        status: "published",
        reviewed_by_id: approver && approver.id,
        reviewed_at: now
      })

    ensure_embeddings(doc.id)
    result
  end

  @doc """
  Admin manual rejection: quarantine a document as `rejected` so it stays out of
  retrieval (only `published` docs are searchable) without deleting the file.
  """
  def reject_document(%Document{} = doc, approver \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    update_document(doc, %{
      status: "rejected",
      reviewed_by_id: approver && approver.id,
      reviewed_at: now
    })
  end

  @doc """
  Enqueue embedding generation for a document if any chunk is missing a vector.
  Idempotent: `EmbedChunksWorker` filters `embedding IS NULL`.
  """
  # Enqueue embedding only when there is actually something to embed. A doc
  # with no chunks yet (save-then-extract path — chunking happens later, in the
  # embed step) or with all chunks embedded would produce a no-op worker run
  # whose "done" entry misleads under the still-pending embed step in prepare.
  def ensure_embeddings(doc_id) do
    pending? =
      Repo.exists?(from c in Chunk, where: c.document_id == ^doc_id and is_nil(c.embedding))

    if pending? do
      unless testing?() do
        %{document_id: doc_id}
        |> RuleMaven.Workers.EmbedChunksWorker.new()
        |> Oban.insert()
      end

      :enqueued
    else
      :noop
    end
  end

  def update_document(%Document{} = doc, attrs, opts \\ []) do
    result =
      doc
      |> Document.changeset(derive_pages(attrs))
      |> Repo.update()

    # Re-chunk when the text actually changed so RAG retrieval stays in sync and
    # demote stale cached answers. Rulebook-derived content (suggestions, facts,
    # setup, categories) is NOT regenerated here — that's the explicit finalize
    # step (`generate_all/1`), run once the admin is happy with the source.
    # `chunk: false` skips the re-chunk — extraction uses it so the embed step
    # doesn't run (and read as done) before cleanup.
    case result do
      {:ok, updated} when updated.full_text != doc.full_text ->
        if Keyword.get(opts, :chunk, true), do: chunk_document(updated)
        regenerate_document_html(updated)
        invalidate_pool(updated.game_id)
        result

      _ ->
        result
    end
  end

  @doc """
  Re-renders the source's "View as HTML" file from its current effective
  (cleaned||original) text. No-op for sources without a backing PDF (e.g.
  hand-pasted text, which has no html file). Called whenever the text changes
  (edit, cleanup) so the HTML view stays in sync.
  """
  def regenerate_document_html(%Document{pdf_path: pdf_path} = doc)
      when is_binary(pdf_path) and pdf_path != "" do
    text = rebuild_full_text(doc.pages)

    case RuleMaven.RulebookDownloader.text_to_html(text, pdf_path) do
      nil ->
        :error

      html_path ->
        if html_path != doc.html_path do
          Repo.update_all(from(d in Document, where: d.id == ^doc.id),
            set: [html_path: html_path]
          )
        end

        :ok
    end
  end

  def regenerate_document_html(_doc), do: :ok

  @doc """
  Regenerates the "View as HTML" file for every source backed by a PDF, from its
  current effective text. Used to roll out template changes (e.g. new theming) to
  already-ingested rulebooks. Returns the number of sources regenerated.
  """
  def regenerate_all_document_html do
    from(d in Document, where: not is_nil(d.pdf_path) and d.pdf_path != "")
    |> Repo.all()
    |> Enum.map(&regenerate_document_html/1)
    |> length()
  end

  @doc """
  Fires every rulebook-derived generator for a game in one shot: suggested
  questions, question categories, "Did you know?" facts, and the setup
  checklist. This is the "finalize" action — generation is never automatic on
  upload/edit/clean, so an admin runs it explicitly once satisfied with the
  source quality, against clean reviewed text. Each worker is `unique` per game
  and no-ops in test, so repeat finalizes coalesce safely.
  """
  def generate_all(game_id) do
    RuleMaven.Workers.SuggestionsWorker.enqueue(game_id)
    RuleMaven.Workers.CategoriesWorker.enqueue(game_id)
    RuleMaven.Workers.DidYouKnowWorker.enqueue(game_id)
    RuleMaven.Workers.VoiceSuggestionsWorker.enqueue(game_id)

    case Repo.get(Game, game_id) do
      %Game{} = game -> RuleMaven.Setup.generate_async(game)
      _ -> :ok
    end

    :ok
  end

  # Derive first-class pages from full_text when a caller supplies text but not
  # pages (e.g. hand-pasted rulebook text). Extraction paths pass :pages
  # explicitly with printed-page detection, so they're left untouched. Updates
  # without :full_text (status/review changes) are also left alone.
  defp derive_pages(attrs) do
    has_pages? = Map.has_key?(attrs, :pages) or Map.has_key?(attrs, "pages")
    full_text = attrs[:full_text] || attrs["full_text"]

    if not has_pages? and is_binary(full_text) do
      Map.put(attrs, :pages, pages_from_full_text(full_text))
    else
      attrs
    end
  end

  def delete_document(%Document{} = doc) do
    # Cancel any in-flight cleanup/cheatsheet jobs for this document so they
    # don't wake up, fail get_document!/1, and burn retries on a row that's gone.
    cancel_document_jobs(doc.id)
    # Remove the stored PDF/HTML from disk (the DB row alone wouldn't).
    remove_document_files(doc)

    # chunks + cheatsheet_versions are removed by FK cascade; the explicit chunk
    # delete is belt-and-suspenders.
    Repo.delete_all(from c in Chunk, where: c.document_id == ^doc.id)
    result = Repo.delete(doc)

    with {:ok, _} <- result do
      # Removing a rulebook can make cached answers stale — demote them.
      invalidate_pool(doc.game_id)

      # If that was the game's last rulebook, also drop the per-game generation
      # caches (cheat sheet, suggestions, categories).
      if document_count(doc.game_id) == 0, do: clear_game_generation_state(doc.game_id)
    end

    result
  end

  defp document_count(game_id) do
    Repo.aggregate(from(d in Document, where: d.game_id == ^game_id), :count)
  end

  @doc """
  When the game's pipeline was last reset (a `DateTime`), or `nil` if never.
  The Prepare page uses this to scope its cost readout to post-reset spend.
  """
  def preparation_reset_at(game_id) do
    case RuleMaven.Settings.get("prep_reset_at_#{game_id}") do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Reset a game's whole prepare pipeline back to its blank, pre-prepare state:
  delete every rulebook source (files, chunks, extracted/cleaned pages) and clear
  every generated artifact (suggestions, categories, cheat sheet, setup, did-you-
  know, voices, theme palette). The game row and its `bgg_data` are kept.

  Refuses with `{:error, :has_questions}` if any question has been logged for the
  game — a destructive wipe shouldn't be possible once players have engaged. The
  caller (Prepare page) also gates the UI, so this is defense-in-depth.

  Idempotent: safe to run when documents/artifacts are already gone.
  """
  def reset_preparation(%Game{} = game) do
    if question_count(game) > 0 do
      {:error, :has_questions}
    else
      # delete_document/1 handles per-source files, chunks, pool invalidation, and
      # (on the last source) clear_game_generation_state.
      Enum.each(list_documents(game), &delete_document/1)

      RuleMaven.CheatSheet.clear(game.id)
      RuleMaven.Setup.clear(game.id)
      RuleMaven.Voices.clear_for_game(game.id)
      Repo.delete_all(from c in GameCategory, where: c.game_id == ^game.id)

      Enum.each(
        ~w(suggestions categories did_you_know),
        &RuleMaven.Settings.delete("#{&1}_#{game.id}")
      )

      # Belt-and-suspenders: covers the no-documents case where delete_document's
      # last-source hook never fired.
      clear_game_generation_state(game.id)
      # update_all rather than update_game/2 so a stale in-memory `game` (theme set
      # after it was loaded) can't make the change look like a no-op.
      Repo.update_all(from(g in Game, where: g.id == ^game.id), set: [theme_palette: nil])

      # Stamp the reset time so the Prepare page can scope its "actual cost"
      # readout to post-reset spend. The llm_logs rows themselves are kept —
      # they feed the global cost dashboard + spend cap — so we bound the display
      # rather than delete history.
      RuleMaven.Settings.put(
        "prep_reset_at_#{game.id}",
        DateTime.utc_now() |> DateTime.to_iso8601()
      )

      :ok
    end
  end

  @doc """
  Drop a game's cached answers from the answer pool AND from same-user reuse.
  Called whenever the game's rulebook content materially changes
  (new/edited/cleaned/deleted source) so stale answers — computed against the
  old text — stop being served by `find_similar_question_in_pool/3` OR by the
  same-user tiers (`find_user_duplicate/4`, `find_user_similar/4`,
  `find_user_answer_duplicate/4`), which all filter on `stale == false`.
  Content-staleness (`stale`) is deliberately a separate field from
  `needs_review`: `needs_review` doubles as a per-user abuse signal
  (`RuleMaven.Moderation.answer_stats_by_user/0`), so flagging every row in
  the game on every rulebook edit would inflate ordinary askers' moderation
  risk score for no abuse-related reason. `stale` carries no moderation
  weight — it's set on every row (any visibility), auto-pooled (`pooled =
  true`) rows are demoted outright, and community rows are additionally
  flagged `needs_review` so they stay out of the shared pool until a
  moderator re-approves them (`clear_needs_review/1`); private rows just
  silently stop matching `stale == false` and a fresh ask re-populates them.
  When a game is an expansion, also invalidates base-game answers that
  included it in their expansion set.
  Returns the number of rows touched (demoted + newly staled + newly
  flagged).
  """
  def invalidate_pool(game_id) do
    # Auto-pooled answers can be demoted silently — they'll re-pool on the next
    # ask against the new text.
    {demoted, _} =
      Repo.update_all(
        from(q in QuestionLog,
          where:
            (q.game_id == ^game_id or fragment("? = ANY(?)", ^game_id, q.expansion_ids)) and
              q.pooled == true
        ),
        set: [pooled: false]
      )

    # Mark every not-yet-stale row in the game — this is the content-staleness
    # signal the same-user cache tiers check, independent of moderation.
    {staled, _} =
      Repo.update_all(
        from(q in QuestionLog,
          where:
            (q.game_id == ^game_id or fragment("? = ANY(?)", ^game_id, q.expansion_ids)) and
              q.stale == false
        ),
        set: [stale: true]
      )

    # Community rows also get needs_review so they leave the shared pool until
    # a moderator re-approves them (clear_needs_review/1). Scoped to community
    # only — same as pre-existing moderation semantics — so an ordinary user's
    # abuse-risk score (needs_review * 2 in moderation.ex) is never inflated by
    # a rulebook edit.
    {flagged, _} =
      Repo.update_all(
        from(q in QuestionLog,
          where:
            (q.game_id == ^game_id or fragment("? = ANY(?)", ^game_id, q.expansion_ids)) and
              q.visibility == "community" and q.needs_review == false
        ),
        set: [needs_review: true]
      )

    # Drop cached persona restyles too — they render stale prose once the
    # underlying answer can change.
    RuleMaven.Voices.clear_for_game(game_id)

    demoted + staled + flagged
  end

  @doc """
  Clears the review flag on an answer, making it pool-eligible again. Also
  clears `stale` — moderator re-approval asserts the answer is still valid
  against the current rulebook text, so it shouldn't stay excluded from the
  same-user cache tiers either.
  """
  def clear_needs_review(%QuestionLog{} = q) do
    q |> QuestionLog.changeset(%{needs_review: false, stale: false}) |> Repo.update()
  end

  @doc """
  Count of community answers flagged stale by a rulebook change and awaiting
  re-approval. These stop serving until cleared, so a non-zero count is a
  moderation backlog that should be drained.
  """
  def needs_review_count do
    Repo.aggregate(
      from(q in QuestionLog, where: q.needs_review == true and q.visibility == "community"),
      :count
    )
  end

  @doc """
  Answers currently pulled from the pool awaiting re-approval (`needs_review`),
  whether pulled by a rulebook change or by user reports. Newest first, with the
  game preloaded for display.
  """
  def list_needs_review_questions do
    Repo.all(
      from q in QuestionLog,
        where: q.needs_review == true,
        order_by: [desc: q.updated_at],
        preload: [:game]
    )
  end

  # ── User answer flags ──

  @doc """
  Records a user's report that an answer is wrong/bad. One flag per user per
  answer (re-flagging re-opens a resolved flag and updates the reason). The flag
  is community signal for moderators — it does not change what the answer serves.
  """
  def flag_question(question_log_id, user_id, reason \\ nil)

  def flag_question(_question_log_id, nil, _reason), do: {:error, "Not logged in."}

  def flag_question(question_log_id, user_id, reason) do
    %QuestionFlag{}
    |> QuestionFlag.changeset(%{
      question_log_id: question_log_id,
      user_id: user_id,
      reason: reason,
      resolved: false
    })
    |> Repo.insert(
      on_conflict: [set: [reason: reason, resolved: false, updated_at: DateTime.utc_now()]],
      conflict_target: [:user_id, :question_log_id]
    )
  end

  # ── Report = flag + trust-tiered auto-pull ───────────────────────────────
  # A user "Report" both records a flag (for moderator review) and, depending on
  # how trusted the answer is, may pull it from the pool immediately. The pull
  # threshold scales with trust so one bad actor can't blank a valuable cache:
  #   • provisional (auto-cached, unreviewed) → pulled on the first flag; cheap
  #     to yank and it self-heals on the next ask.
  #   • trusted / community → pulled only once `flag_quorum` *distinct,
  #     non-suspended* users have an open flag; below that it just queues.
  #   • admin-verified → never auto-pulled; only a moderator can.
  @flag_quorum_default 3
  @flag_limit_daily_default 20

  @doc """
  Records a report on an answer and applies the trust-tiered auto-pull policy.
  Returns `{:ok, %{pulled: boolean}}` or `{:error, message}` (quota/insert).
  """
  def report_answer(question_log_id, user) do
    with :ok <- check_flag_quota(user),
         {:ok, _flag} <- flag_question(question_log_id, user.id) do
      {:ok, %{pulled: maybe_auto_pull(question_log_id)}}
    end
  end

  # Caps reports per user per rolling day so mass-flagging can't grief the queue
  # or knock answers offline en masse. Admins are exempt.
  defp check_flag_quota(user) do
    if RuleMaven.Users.can?(user, :admin) do
      :ok
    else
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      count =
        Repo.one(
          from f in QuestionFlag,
            where: f.user_id == ^user.id and f.updated_at >= ^since,
            select: count(f.id)
        ) || 0

      limit = parse_limit(RuleMaven.Settings.get("flag_limit_daily"), @flag_limit_daily_default)

      if count >= limit,
        do: {:error, "Daily report limit reached. Thanks — a moderator will review the rest."},
        else: :ok
    end
  end

  # Decides whether this flag pulls the row now. Returns true if it did.
  defp maybe_auto_pull(question_log_id) do
    case Repo.get(QuestionLog, question_log_id) do
      nil ->
        false

      %QuestionLog{needs_review: true} ->
        # Already out of the pool — nothing more to do.
        false

      %QuestionLog{verified: true} ->
        # Admin sign-off is never undone by users.
        false

      %QuestionLog{} = q ->
        case pool_tier(q) do
          :provisional ->
            set_needs_review(question_log_id)
            true

          :trusted ->
            quorum = parse_limit(RuleMaven.Settings.get("flag_quorum"), @flag_quorum_default)

            if open_flagger_count(question_log_id) >= quorum do
              set_needs_review(question_log_id)
              true
            else
              false
            end
        end
    end
  end

  # Distinct, non-suspended users with an open flag on this answer. Suspended
  # accounts are excluded so a banned griefer (or a ring of them) can't push a
  # trusted answer over quorum.
  defp open_flagger_count(question_log_id) do
    Repo.one(
      from f in QuestionFlag,
        join: u in RuleMaven.Users.User,
        on: u.id == f.user_id,
        where:
          f.question_log_id == ^question_log_id and f.resolved == false and
            is_nil(u.suspended_at),
        select: count(f.user_id, :distinct)
    ) || 0
  end

  defp set_needs_review(question_log_id) do
    from(q in QuestionLog, where: q.id == ^question_log_id)
    |> Repo.update_all(set: [needs_review: true])
  end

  @doc "Set of question_log ids this user has an open (unresolved) flag on."
  def user_flagged_ids(nil), do: MapSet.new()

  def user_flagged_ids(user_id) do
    Repo.all(
      from f in QuestionFlag,
        where: f.user_id == ^user_id and f.resolved == false,
        select: f.question_log_id
    )
    |> MapSet.new()
  end

  @doc "Count of distinct answers with at least one open flag (admin badge)."
  def count_pending_flags do
    Repo.one(
      from f in QuestionFlag,
        where: f.resolved == false,
        select: count(f.question_log_id, :distinct)
    ) || 0
  end

  @doc """
  Flagged answers awaiting moderator review, most-flagged first. Each entry is
  the question row plus its open-flag count and the distinct reasons given.
  """
  def list_flagged_questions do
    agg =
      Repo.all(
        from f in QuestionFlag,
          where: f.resolved == false,
          group_by: f.question_log_id,
          select: %{
            question_log_id: f.question_log_id,
            flag_count: count(f.id),
            reasons: fragment("array_remove(array_agg(DISTINCT ?), NULL)", f.reason)
          }
      )

    ids = Enum.map(agg, & &1.question_log_id)
    questions = Repo.all(from q in QuestionLog, where: q.id in ^ids) |> Map.new(&{&1.id, &1})

    agg
    |> Enum.map(fn a -> Map.put(a, :question, Map.get(questions, a.question_log_id)) end)
    |> Enum.filter(& &1.question)
    |> Enum.sort_by(& &1.flag_count, :desc)
  end

  @doc "Resolves (dismisses) all open flags on an answer. Returns the count cleared."
  def resolve_flags(question_log_id) do
    {n, _} =
      Repo.update_all(
        from(f in QuestionFlag,
          where: f.question_log_id == ^question_log_id and f.resolved == false
        ),
        set: [resolved: true, updated_at: DateTime.utc_now()]
      )

    n
  end

  @doc """
  Re-chunk (and re-embed) every document, e.g. after changing how chunk text is
  derived. `chunk_document/1` clears + reinserts chunks and enqueues embedding.
  Also invalidates the pool for every affected game — the re-chunk changes what
  retrieval sees, so cached answers computed against the old chunks are stale.
  Returns the number of documents processed.
  """
  def rechunk_all_documents do
    docs = Repo.all(Document)
    Enum.each(docs, &chunk_document/1)

    docs
    |> Enum.map(& &1.game_id)
    |> Enum.uniq()
    |> Enum.each(&invalidate_pool/1)

    length(docs)
  end

  @doc_job_workers ~w(RuleMaven.Workers.CleanupWorker RuleMaven.Workers.CheatSheetWorker)
  @cancellable_states ~w(available scheduled executing retryable)

  defp cancel_document_jobs(doc_id) do
    if oban_running?() do
      from(j in Oban.Job,
        where:
          j.worker in ^@doc_job_workers and j.state in ^@cancellable_states and
            fragment("?->>'document_id' = ?", j.args, ^to_string(doc_id))
      )
      |> Oban.cancel_all_jobs()
    end
  end

  defp remove_document_files(doc) do
    for path <- [doc.pdf_path, doc.html_path], is_binary(path) and path != "" do
      :rule_maven
      |> Application.app_dir("priv/static/#{path}")
      |> File.rm()
    end
  end

  defp clear_game_generation_state(game_id) do
    ~w(cheat_status cheat_content cheat_error cheat_started cheat_level
       cheat_cancelled cheat_provider cheat_model cheat_elapsed
       suggestions categories download_error)
    |> Enum.each(&RuleMaven.Settings.delete("#{&1}_#{game_id}"))
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual

  def document_full_text(%Game{} = game) do
    game
    |> list_documents()
    |> Enum.map_join("\n\n", & &1.full_text)
  end

  # ── Rulebook cleanup (durable, Oban-backed) ──

  @cleanup_worker "RuleMaven.Workers.CleanupWorker"
  @cleanup_active_states ~w(available scheduled executing retryable suspended)

  @doc """
  Persist one page's cleaned text into the document's embedded pages and refresh
  the derived `full_text`. Reloads the document each call so concurrent per-page
  writes from the cleanup worker accumulate correctly on the embeds_many column.
  Does NOT re-chunk (the worker chunks once at the end).
  """
  def set_page_cleaned(doc_id, index, cleaned, defects \\ nil) do
    doc = get_document!(doc_id)

    pages =
      Enum.map(doc.pages, fn p ->
        attrs = page_attrs(p)

        cond do
          p.index != index -> attrs
          # A defects list (possibly empty) is the cleanup critic's verdict for
          # this pass — it replaces whatever was recorded before, so a faithful
          # re-clean un-flags the page. `nil` (manual edits) leaves it alone.
          is_list(defects) -> %{attrs | cleaned: cleaned, cleanup_defects: defects}
          true -> %{attrs | cleaned: cleaned}
        end
      end)

    doc
    |> Document.changeset(%{pages: pages, full_text: rebuild_full_text(pages)})
    |> Repo.update()
  end

  @doc """
  Null every page's cleaned layer (used to start a fresh full re-clean). Returns
  the reloaded document.
  """
  def clear_all_cleaned(%Document{} = doc) do
    pages = Enum.map(doc.pages, fn p -> %{page_attrs(p) | cleaned: nil} end)

    {:ok, updated} =
      doc
      |> Document.changeset(%{pages: pages, full_text: rebuild_full_text(pages)})
      |> Repo.update()

    updated
  end

  # Confidence at/below this → the extraction gate wasn't sure about the page;
  # surface it for human review. Picks up critic-residual pages (0.5) but not
  # blank/agreed pages (0.6+).
  @review_threshold 0.6

  @doc """
  True when a page warrants human review: the extraction gate's confidence is
  low, or the last cleanup pass left residual defects on record. Pages with no
  confidence (native/clean-layer/legacy) and no defects are never flagged.
  """
  def page_needs_review?(page) do
    c = Map.get(page, :confidence)
    defects = Map.get(page, :cleanup_defects)
    (is_number(c) and c < @review_threshold) or (is_list(defects) and defects != [])
  end

  @doc "Count of pages on a document (or page list) flagged for review."
  def review_page_count(%Document{pages: pages}), do: review_page_count(pages)
  def review_page_count(pages) when is_list(pages), do: Enum.count(pages, &page_needs_review?/1)

  defp page_attrs(p) do
    %{
      index: p.index,
      sheet: p.sheet,
      printed: p.printed,
      text: p.text || "",
      cleaned: p.cleaned,
      confidence: Map.get(p, :confidence),
      lane: Map.get(p, :lane),
      source: Map.get(p, :source),
      # Preserve decision-log detail across round-trips (edits, cleanup, re-extract).
      gate_agreement: Map.get(p, :gate_agreement),
      gate_coverage: Map.get(p, :gate_coverage),
      escalated: Map.get(p, :escalated),
      critic_rounds: Map.get(p, :critic_rounds),
      residual_defects: Map.get(p, :residual_defects),
      cleanup_defects: Map.get(p, :cleanup_defects)
    }
  end

  @doc """
  True when a cleanup job for this document is queued or running. Single source
  of truth for "is this rulebook being cleaned" — survives server restarts since
  it reads Oban's durable job state, not in-memory flags.
  """
  def cleanup_running?(doc_id) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@cleanup_worker and
            j.state in ^@cleanup_active_states and
            fragment("?->>'document_id' = ?", j.args, ^to_string(doc_id))
    )
  end

  @doc """
  Enqueue (or no-op if one is already active) a durable cleanup of a document's
  pages at the given strength (`:auto | :light | :standard | :aggressive`;
  auto = escalation loop).

  `mode`:
    * `:raw` (default) — full clean from the original extraction; clears any
      existing cleaned text first.
    * `:again` — a second pass over the *current* cleaned text to scrub leftover
      junk. Keeps the cleaned text (it's the input to the re-clean).
  """
  def enqueue_cleanup(%Document{} = doc, level \\ :auto, mode \\ :raw) do
    if mode == :raw, do: clear_all_cleaned(doc)
    # Reset the durable progress counter so this run starts at 0/total.
    set_cleaning_done(doc.id, 0)

    %{document_id: doc.id, game_id: doc.game_id, level: to_string(level), mode: to_string(mode)}
    |> RuleMaven.Workers.CleanupWorker.new()
    |> Oban.insert()
  end

  @doc """
  Enqueue a durable cleanup of a single page (by `index`) — always a fresh
  clean from that page's original extraction; the page's existing cleaned text
  is replaced when the worker persists the result, other pages are untouched.
  Same `unique`-per-document worker as `enqueue_cleanup/3`, so a page clean
  can't race a whole-document clean.
  """
  def enqueue_cleanup_page(%Document{} = doc, index, level \\ :auto) do
    set_cleaning_done(doc.id, 0)

    %{
      document_id: doc.id,
      game_id: doc.game_id,
      level: to_string(level),
      mode: "raw",
      page_index: index
    }
    |> RuleMaven.Workers.CleanupWorker.new()
    |> Oban.insert()
  end

  @extract_worker "RuleMaven.Workers.ExtractWorker"

  @doc """
  True when an extraction job for this document is queued or running. Reads
  Oban's durable job state so it survives restarts (mirrors cleanup_running?/1).
  """
  def extract_running?(doc_id) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@extract_worker and
            j.state in ^@cleanup_active_states and
            fragment("?->>'document_id' = ?", j.args, ^to_string(doc_id))
    )
  end

  @doc """
  Enqueue a durable text extraction for a saved-but-unextracted document (no-op
  in test, where Oban isn't supervised). Idempotent per document — the worker is
  `unique` on document_id and `extract_running?/1` guards callers.
  """
  def enqueue_extract(%Document{} = doc) do
    if testing?() do
      :ok
    else
      %{document_id: doc.id, game_id: doc.game_id}
      |> RuleMaven.Workers.ExtractWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Sets the durable cleanup progress counter for a document (pages persisted so
  far this run), or nil when idle. Written via `update_all` so it never touches
  the `pages` embed. Returns the value it set.
  """
  def set_cleaning_done(doc_id, value) do
    Repo.update_all(from(d in Document, where: d.id == ^doc_id), set: [cleaning_done: value])
    value
  end

  @doc "Durable cleanup progress (pages persisted this run), or nil when idle."
  def cleaning_done(doc_id) do
    Repo.one(from d in Document, where: d.id == ^doc_id, select: d.cleaning_done)
  end

  # Backward compat aliases
  defdelegate list_rulebook_sources(game), to: __MODULE__, as: :list_documents
  defdelegate create_rulebook_source(attrs), to: __MODULE__, as: :create_document
  defdelegate delete_rulebook_source(doc), to: __MODULE__, as: :delete_document
  defdelegate rulebook_text(game), to: __MODULE__, as: :document_full_text

  def rulebook_text_for_games(game_ids) do
    game_ids
    |> Enum.map(fn gid ->
      game = Repo.get!(Game, gid)
      text = document_full_text(game)
      "--- #{game.name} ---\n#{text}"
    end)
    |> Enum.reject(fn t -> String.trim(t) == "---" end)
    |> Enum.join("\n\n")
  end

  # ── Question Log ──

  def log_question(attrs) do
    %QuestionLog{}
    |> QuestionLog.changeset(attrs)
    |> Repo.insert()
  end

  def log_question_update(%QuestionLog{} = q, attrs) do
    q
    |> QuestionLog.changeset(attrs)
    |> Repo.update()
  end

  @doc "Fetch one question_log row by id, or nil."
  def get_question_log(id), do: Repo.get(QuestionLog, id)

  def question_count(%Game{} = game) do
    Repo.aggregate(from(q in QuestionLog, where: q.game_id == ^game.id), :count)
  end

  # Counts a user's *billable* asks since `since` — fresh LLM generations only.
  # Cache/pool hits (rows carrying a `pool_source_id`) are cheap and explicitly
  # don't count against rate limits or quotas.
  def recent_question_count(user_id, since) do
    Repo.aggregate(
      from(q in QuestionLog,
        where: q.user_id == ^user_id and q.inserted_at >= ^since and is_nil(q.pool_source_id)
      ),
      :count
    )
  end

  def grouped_questions(%Game{} = game, opts \\ []) do
    all = recent_questions(game, 200, opts)

    # Group by exact question text (same question asked again = regen history).
    # Questions are self-contained — no followup threading.
    all
    |> Enum.group_by(&String.downcase(String.trim(&1.question)))
    |> Enum.map(fn {_key, entries} ->
      sorted =
        entries
        |> Enum.sort(fn a, b ->
          case {a.verified, b.verified} do
            {true, false} -> true
            {false, true} -> false
            _ -> NaiveDateTime.compare(a.inserted_at, b.inserted_at) == :gt
          end
        end)

      primary = List.first(sorted)
      history = if length(sorted) > 1, do: tl(sorted), else: []

      %{primary: primary, history: history, followups: []}
    end)
    |> Enum.sort_by(& &1.primary.inserted_at, {:desc, DateTime})
  end

  def toggle_favorite(nil), do: {:error, :not_found}

  def toggle_favorite(%QuestionLog{} = q) do
    q |> QuestionLog.changeset(%{favorited: !q.favorited}) |> Repo.update()
  end

  @doc """
  Toggles an admin "verified" sign-off — a single publish/unpublish action.

  Verifying is the strongest trust signal, so it bypasses the usual citation
  gate and scheduled promotion: the row is immediately made community-visible and
  pool-eligible, its trust_score floored to the top tier, and the author's
  reputation rewarded — citation or not. Any other verified row with the same
  question text is cleared (one verified answer per question).

  Un-verifying reverts it: back to private, pool-eligibility falls back to the
  citation gate, and trust/reputation are recomputed. (A row that independently
  earned community status by votes can be re-published via the visibility toggle.)
  """
  def toggle_verified(%QuestionLog{} = q) do
    if q.verified, do: do_unverify(q), else: do_verify(q)
  end

  defp do_verify(%QuestionLog{} = q) do
    # At most one verified answer per question. Clear any existing verified row
    # for the *same* question — matched by embedding similarity (so paraphrases
    # don't both stay verified), falling back to exact wording when this row has
    # no embedding yet.
    unverify_duplicates(q)

    attrs = %{verified: true, visibility: "community", pooled: true}

    with {:ok, updated} <- Repo.update(QuestionLog.changeset(q, attrs)) do
      finalize_verify_toggle(updated)
    end
  end

  defp unverify_duplicates(%QuestionLog{question_embedding: nil} = q) do
    from(ql in QuestionLog,
      where:
        ql.game_id == ^q.game_id and ql.id != ^q.id and
          ql.question == ^q.question and ql.verified == true
    )
    |> Repo.all()
    |> Enum.each(&demote_verified_duplicate/1)
  end

  defp unverify_duplicates(%QuestionLog{} = q) do
    threshold = pool_distance_threshold()

    from(ql in QuestionLog,
      where:
        ql.game_id == ^q.game_id and ql.id != ^q.id and ql.verified == true and
          not is_nil(ql.question_embedding) and
          fragment(
            "cosine_distance(?, ?::vector)",
            ql.question_embedding,
            ^q.question_embedding
          ) <= ^threshold
    )
    |> Repo.all()
    |> Enum.each(&demote_verified_duplicate/1)
  end

  # Fully demote a superseded verified row instead of just flipping the flag:
  # clearing `verified` alone left the row at visibility "community" with the
  # verified trust_score floor (100), so it stayed in the trusted tier. Mirror
  # do_unverify so the old answer actually steps down and is re-scored.
  defp demote_verified_duplicate(%QuestionLog{} = dup) do
    attrs = %{verified: false, visibility: "private", pooled: dup.citation_valid}

    with {:ok, updated} <- Repo.update(QuestionLog.changeset(dup, attrs)) do
      finalize_verify_toggle(updated)
    end
  end

  @doc """
  Moderation kill-switch: makes every non-private answer authored by `user_id`
  private and removes it from the pool (unlike `do_unverify`, this drops pooling
  even for grounded citations — a bad actor's answers should stop serving). Trust
  is recomputed per row, the author's reputation re-derived once, and persona
  restyle caches cleared for each affected game. Returns the number demoted.
  """
  def demote_user_answers(user_id) when is_integer(user_id) do
    rows =
      Repo.all(
        from q in QuestionLog,
          where:
            q.user_id == ^user_id and
              (q.visibility != "private" or q.pooled == true or q.verified == true)
      )

    Enum.each(rows, fn q ->
      {:ok, updated} =
        q
        |> QuestionLog.changeset(%{
          visibility: "private",
          pooled: false,
          verified: false,
          needs_review: false
        })
        |> Repo.update()

      RuleMaven.Games.Trust.recompute_trust(updated)
    end)

    RuleMaven.Games.Trust.recompute_reputation(user_id)

    rows
    |> Enum.map(& &1.game_id)
    |> Enum.uniq()
    |> Enum.each(&RuleMaven.Voices.clear_for_game/1)

    length(rows)
  end

  defp do_unverify(%QuestionLog{} = q) do
    attrs = %{
      verified: false,
      visibility: "private",
      # Stay pooled only if the citation is grounded (not merely present).
      pooled: q.citation_valid
    }

    with {:ok, updated} <- Repo.update(QuestionLog.changeset(q, attrs)) do
      finalize_verify_toggle(updated)
    end
  end

  defp finalize_verify_toggle(%QuestionLog{} = updated) do
    RuleMaven.Games.Trust.recompute_trust(updated)
    if updated.user_id, do: RuleMaven.Games.Trust.recompute_reputation(updated.user_id)
    {:ok, updated}
  end

  def update_question_visibility(%QuestionLog{} = q, visibility) do
    # Promoting to community makes the row cache-eligible.
    attrs = %{visibility: visibility, pooled: visibility == "community" or q.pooled}

    with {:ok, updated} <- q |> QuestionLog.changeset(attrs) |> Repo.update() do
      # Keep trust_score consistent with the new tier (community floors it), and
      # the author's reputation consistent with the promotion bonus (reputation
      # counts community rows × bonus, so a tier change must re-derive it).
      RuleMaven.Games.Trust.recompute_trust(updated)
      if updated.user_id, do: RuleMaven.Games.Trust.recompute_reputation(updated.user_id)
      {:ok, updated}
    end
  end

  @doc """
  Sets the admin-curated canonical question/answer on a row (the FAQ text that
  serves and embeds in place of the raw Q&A). Blank strings clear back to nil.
  Re-embeds via EmbedQuestionWorker so search reflects the new canonical text.
  Does NOT change visibility — promotion stays a separate, explicit action.
  """
  def update_canonical(%QuestionLog{} = q, canonical_question, canonical_answer) do
    attrs = %{
      canonical_question: blank_to_nil(canonical_question),
      canonical_answer: blank_to_nil(canonical_answer)
    }

    with {:ok, updated} <- q |> QuestionLog.changeset(attrs) |> Repo.update() do
      # Skip the re-embed enqueue under manual Oban (tests); enqueue in prod.
      unless Application.get_env(:rule_maven, Oban)[:testing] == :manual do
        RuleMaven.Workers.EmbedQuestionWorker.enqueue(updated.id)
      end

      {:ok, updated}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  def set_question_visibility(id, visibility) when is_integer(id) do
    set = [visibility: visibility]
    set = if visibility == "community", do: Keyword.put(set, :pooled, true), else: set
    Repo.update_all(from(q in QuestionLog, where: q.id == ^id), set: set)

    if q = Repo.get(QuestionLog, id) do
      RuleMaven.Games.Trust.recompute_trust(q)
      if q.user_id, do: RuleMaven.Games.Trust.recompute_reputation(q.user_id)
    end
  end

  def check_rate_limit(nil), do: {:error, "Not logged in."}

  def check_rate_limit(user) do
    alias RuleMaven.Users
    alias RuleMaven.Settings

    if Users.can?(user, :admin) do
      :ok
    else
      now = DateTime.utc_now()

      daily_count = recent_question_count(user.id, DateTime.add(now, -1, :day))
      weekly_count = recent_question_count(user.id, DateTime.add(now, -7, :day))
      monthly_count = recent_question_count(user.id, DateTime.add(now, -30, :day))

      daily_limit = parse_limit(Settings.get("rate_limit_daily"), 50)
      weekly_limit = parse_limit(Settings.get("rate_limit_weekly"), 200)
      # Monthly is the per-user, admin-tunable quota — not a global setting.
      monthly_limit = user.monthly_quota || 200

      # Daily $ budget cap (0 = disabled). Estimated from logged token usage.
      cost_cap = parse_cost(Settings.get("user_daily_cost_cap"), 0.0)

      cond do
        daily_count >= daily_limit ->
          {:error, "Daily question limit reached (#{daily_limit})."}

        weekly_count >= weekly_limit ->
          {:error, "Weekly question limit reached (#{weekly_limit})."}

        monthly_count >= monthly_limit ->
          {:error, "Monthly question quota reached (#{monthly_limit}). An admin can raise it."}

        cost_cap > 0.0 and RuleMaven.LLM.user_cost_today(user.id) >= cost_cap ->
          {:error, "Daily usage budget reached. Please try again tomorrow."}

        true ->
          :ok
      end
    end
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(val, default) do
    case Integer.parse(to_string(val)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_cost(nil, default), do: default

  defp parse_cost(val, default) do
    case Float.parse(to_string(val)) do
      {n, _} -> n
      :error -> default
    end
  end

  def faq_questions(%Game{} = game, limit \\ 200) do
    Repo.all(
      from q in QuestionLog,
        where: q.game_id == ^game.id and q.visibility == "community" and q.refused == false,
        order_by: [desc: q.inserted_at],
        limit: ^limit
    )
  end

  def delete_question(%QuestionLog{} = q), do: Repo.delete(q)

  def recent_questions(%Game{} = game, limit \\ 20, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)

    base =
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        order_by: [desc: q.inserted_at],
        limit: ^limit

    query =
      if user_id do
        from q in base,
          where: q.user_id == ^user_id or q.visibility == "community"
      else
        base
      end

    Repo.all(query)
  end

  def admin_list_questions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    game_id = Keyword.get(opts, :game_id)
    status = Keyword.get(opts, :status)
    search = Keyword.get(opts, :search)

    query =
      from q in base_question_query(),
        limit: ^limit,
        preload: [:game, :user]

    query =
      if game_id, do: from(q in query, where: q.game_id == ^game_id), else: query

    query =
      case status do
        "pending" ->
          from(q in query, where: q.answer == "Thinking...")

        "refused" ->
          from(q in query, where: q.refused == true)

        "error" ->
          from(q in query, where: like(q.answer, "⚠️%"))

        "answered" ->
          from(q in query,
            where: q.answer != "Thinking..." and q.refused == false and not like(q.answer, "⚠️%")
          )

        "needs_review" ->
          from(q in query, where: q.needs_review == true)

        _ ->
          query
      end

    query =
      if search && search != "" do
        term = "%#{search}%"
        from(q in query, where: ilike(q.question, ^term) or ilike(q.answer, ^term))
      else
        query
      end

    Repo.all(query)
  end

  def delete_all_questions(%Game{} = game) do
    {count, _} =
      Repo.delete_all(from q in QuestionLog, where: q.game_id == ^game.id)

    {count, nil}
  end

  @doc """
  Returns community-visible FAQ-approved questions for a game.
  Excludes questions by the given user_id when specified.
  """
  def community_questions(%Game{} = game, exclude_user_id \\ nil) do
    query =
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: q.visibility == "community",
        where: q.refused == false,
        order_by: [desc: q.inserted_at],
        limit: 50

    query =
      if exclude_user_id do
        from q in query, where: q.user_id != ^exclude_user_id
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns refused (not covered) root questions for a game, filtered by user.
  """
  def refused_questions(%Game{} = game, user_id \\ nil) do
    query =
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: q.refused == true,
        order_by: [desc: q.inserted_at],
        limit: 50

    query =
      if user_id do
        from q in query, where: q.user_id == ^user_id
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Searches questions by text match for a game. User input is escaped before
  being interpolated into the ILIKE pattern so literal `%`/`_`/`\\` in the
  search box are matched literally instead of acting as SQL wildcards
  (Postgres's LIKE/ILIKE default escape character is `\\`, so no explicit
  `ESCAPE` clause is needed as long as we escape with it).
  """
  def search_questions(%Game{} = game, query_text) do
    search_term = "%#{escape_like(query_text)}%"

    Repo.all(
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: ilike(q.question, ^search_term),
        order_by: [desc: q.inserted_at],
        limit: 50
    )
  end

  # Escapes the three characters ILIKE treats specially — `\` (the escape
  # character itself, must go first so we don't double-escape the escapes we
  # just inserted), `%` (zero-or-more wildcard), and `_` (single-char
  # wildcard) — so user-supplied search text is matched literally.
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Finds a similar question in the cache pool using embedding similarity.

  Eligibility is `pooled = true` (citation-gated, decoupled from `visibility`),
  so citation-backed *private* answers serve the fast-path too. Results are
  ordered trusted-first, then by trust_score, then cosine distance — so a
  trusted (community / verified / above-floor) hit always wins over a provisional
  one. Returns nil or `{question_log, tier}` where tier is `:trusted | :provisional`.

  This is the ONLY surface that widens to private rows, and it serves answer
  text only (never the source row's question wording or author). Browse/list
  surfaces (`community_questions/2`, `faq_questions/2`) stay community-only.

  Distance threshold derives from the `pool_similarity_threshold` setting
  (cosine similarity, default 0.92); cosine distance = 1 - similarity.

  Scoped by `opts[:expansion_ids]` (default `[]`, i.e. base game only) —
  compared sorted ascending against the row's `expansion_ids`, so an answer
  only serves asks made against the exact same expansion set.
  """
  def find_similar_question_in_pool(game_id, question_embedding, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, pool_distance_threshold())
    expansion_ids = opts |> Keyword.get(:expansion_ids, []) |> Enum.sort()
    floor = RuleMaven.Games.Trust.trusted_floor()

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id,
          # An answer only serves asks made against the SAME expansion set —
          # expansions change rules, so a base-only answer can be wrong with
          # an expansion in play (and vice versa).
          where: q.expansion_ids == ^expansion_ids,
          # Community rows are always eligible; private rows once citation-gated.
          where: q.pooled == true or q.visibility == "community",
          where: not is_nil(q.question_embedding),
          where: q.refused == false,
          # Skip answers flagged stale by a rulebook change until re-approved.
          where: q.needs_review == false,
          where:
            fragment(
              "cosine_distance(?, ?::vector)",
              q.question_embedding,
              ^Pgvector.new(question_embedding)
            ) <= ^threshold,
          order_by: [
            # Trusted rows first (community OR verified OR above trust floor)...
            desc:
              fragment(
                "(? = 'community' OR ? OR ? >= ?)",
                q.visibility,
                q.verified,
                q.trust_score,
                ^floor
              ),
            desc: q.trust_score,
            asc:
              fragment(
                "cosine_distance(?, ?::vector)",
                q.question_embedding,
                ^Pgvector.new(question_embedding)
              )
          ],
          limit: 1
      )

    case row do
      nil -> nil
      q -> {q, pool_tier(q, floor)}
    end
  end

  @doc """
  The asker's own most-recent reusable answer for an exact (normalized) repeat of
  their question — independent of pooling and the embedding threshold, so a
  repeat always collapses to one Q&A even when the first answer never pooled.

  Eligible rows: same `user_id` and `game_id`, not
  refused/blocked/needs_review/stale (stale = rulebook changed since the answer
  was computed, set by `invalidate_pool/1`), a real answer (not the in-flight
  "Thinking..." sentinel), and a normalized-text
  match (`cleaned_question == cleaned`, case-insensitive; or `question == raw`
  when `cleaned_question` is null). Returns `{row, tier}` or nil; nil when
  `user_id` is nil.

  Scoped by `expansion_ids` (default `[]`) — compared sorted ascending
  against the row's `expansion_ids`.
  """
  def find_user_duplicate(game_id, user_id, cleaned, raw, expansion_ids \\ [])
  def find_user_duplicate(_game_id, nil, _cleaned, _raw, _expansion_ids), do: nil

  def find_user_duplicate(game_id, user_id, cleaned, raw, expansion_ids) do
    cleaned = String.downcase(to_string(cleaned))
    raw = String.downcase(to_string(raw))
    expansion_ids = Enum.sort(expansion_ids)

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id,
          where: q.expansion_ids == ^expansion_ids,
          where:
            q.refused == false and q.blocked == false and q.needs_review == false and
              q.stale == false,
          where: q.answer != "Thinking..." and not is_nil(q.answer),
          where:
            fragment("lower(?) = ?", q.cleaned_question, ^cleaned) or
              (is_nil(q.cleaned_question) and fragment("lower(?) = ?", q.question, ^raw)),
          order_by: [desc: q.inserted_at, desc: q.id],
          limit: 1
      )

    case row do
      nil -> nil
      q -> {q, pool_tier(q)}
    end
  end

  @doc """
  Same-user semantic fallback: the asker's own closest prior answer above a
  STRICTER similarity floor than the shared pool (`user_dup_similarity_threshold`,
  default 0.95). Stricter because same-user history has no curation/trust gate —
  a loose match would serve a wrong answer with nothing behind it. Returns
  `{row, tier}` or nil; nil when `user_id` or `embedding` is nil.

  Scoped by `opts[:expansion_ids]` (default `[]`) — compared sorted
  ascending against the row's `expansion_ids`.
  """
  def find_user_similar(game_id, user_id, embedding, opts \\ [])
  def find_user_similar(_game_id, nil, _embedding, _opts), do: nil
  def find_user_similar(_game_id, _user_id, nil, _opts), do: nil

  def find_user_similar(game_id, user_id, embedding, opts) do
    threshold = Keyword.get(opts, :threshold, user_dup_distance_threshold())
    expansion_ids = opts |> Keyword.get(:expansion_ids, []) |> Enum.sort()
    vec = Pgvector.new(embedding)

    row =
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id,
          where: q.expansion_ids == ^expansion_ids,
          where:
            q.refused == false and q.blocked == false and q.needs_review == false and
              q.stale == false,
          where: q.answer != "Thinking..." and not is_nil(q.answer),
          where: not is_nil(q.question_embedding),
          where:
            fragment("cosine_distance(?, ?::vector)", q.question_embedding, ^vec) <= ^threshold,
          order_by: [asc: fragment("cosine_distance(?, ?::vector)", q.question_embedding, ^vec)],
          limit: 1
      )

    case row do
      nil -> nil
      q -> {q, pool_tier(q)}
    end
  end

  @doc """
  The asker's own prior row whose ANSWER is (near-)identical to `answer` —
  catches two differently-worded questions that dodged question-similarity but
  produced the same answer. Compares whitespace-collapsed, case-folded answer
  text (near-zero false positives; no fuzzy matching). Excludes `exclude_id`
  (the provisional row) and non-final/refused rows. Returns the row or nil; nil
  when `user_id` is nil or the answer normalizes to empty.

  Scoped by `expansion_ids` (default `[]`) — compared sorted ascending
  against the row's `expansion_ids`.
  """
  def find_user_answer_duplicate(game_id, user_id, answer, exclude_id, expansion_ids \\ [])

  def find_user_answer_duplicate(_game_id, nil, _answer, _exclude_id, _expansion_ids), do: nil

  def find_user_answer_duplicate(game_id, user_id, answer, exclude_id, expansion_ids) do
    norm = normalize_answer_text(answer)
    expansion_ids = Enum.sort(expansion_ids)

    if norm == "" do
      nil
    else
      Repo.one(
        from q in QuestionLog,
          where: q.game_id == ^game_id and q.user_id == ^user_id and q.id != ^exclude_id,
          where: q.expansion_ids == ^expansion_ids,
          where:
            q.refused == false and q.blocked == false and q.needs_review == false and
              q.stale == false,
          where: q.answer != "Thinking..." and not is_nil(q.answer),
          where:
            fragment("btrim(lower(regexp_replace(?, '\\s+', ' ', 'g'))) = ?", q.answer, ^norm),
          order_by: [desc: q.inserted_at, desc: q.id],
          limit: 1
      )
    end
  end

  # Keep in lockstep with the SQL side of find_user_answer_duplicate/4:
  # collapse runs of whitespace to one space, downcase, trim.
  defp normalize_answer_text(answer) do
    answer
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Classifies a pooled row as `:trusted` (community-promoted, admin-verified, or
  above the trust floor) or `:provisional` (citation-backed but unreviewed).
  """
  def pool_tier(%QuestionLog{} = q, floor \\ nil) do
    floor = floor || RuleMaven.Games.Trust.trusted_floor()

    cond do
      # Admin-curated tiers are unconditionally trusted.
      q.visibility == "community" or q.verified ->
        :trusted

      # Earning trust by votes also requires a quorum of distinct, eligible
      # voters — so a single (or sybil) vote can't flip the label to trusted.
      (q.trust_score || 0.0) >= floor and
          RuleMaven.Games.Trust.eligible_voter_count(q) >=
            RuleMaven.Games.Trust.promotion_quorum() ->
        :trusted

      true ->
        :provisional
    end
  end

  @doc """
  Marks a row cache-eligible when it carries a *grounded* citation
  (`citation_valid`) and was not refused. No-op if `pooled` was explicitly
  turned off (a per-account opt-out can set `pooled = false`). Returns the
  (possibly updated) row.
  """
  def mark_pooled(%QuestionLog{pooled: false, refused: false} = q) do
    # Pool only when the citation is grounded in the source (not merely present),
    # so a hallucinated citation can't earn cross-user serving.
    if q.citation_valid do
      case log_question_update(q, %{pooled: true}) do
        {:ok, updated} -> updated
        _ -> q
      end
    else
      q
    end
  end

  def mark_pooled(%QuestionLog{} = q), do: q

  @default_pool_similarity 0.92
  @default_user_dup_similarity 0.95

  # Cosine distance ceiling for a pool hit, derived from the configured
  # similarity floor (distance = 1 - similarity).
  defp pool_distance_threshold do
    sim =
      case RuleMaven.Settings.get("pool_similarity_threshold") do
        nil ->
          @default_pool_similarity

        "" ->
          @default_pool_similarity

        val ->
          case Float.parse(val),
            do: (
              {f, _} -> f
              :error -> @default_pool_similarity
            )
      end

    1.0 - sim
  end

  # Cosine distance ceiling for a same-user semantic hit. Stricter than the pool.
  defp user_dup_distance_threshold do
    sim =
      case RuleMaven.Settings.get("user_dup_similarity_threshold") do
        nil ->
          @default_user_dup_similarity

        "" ->
          @default_user_dup_similarity

        val ->
          case Float.parse(val) do
            {f, _} -> f
            :error -> @default_user_dup_similarity
          end
      end

    1.0 - sim
  end

  # Shared base for admin question listings — single source for ordering.
  defp base_question_query do
    from q in QuestionLog, order_by: [desc: q.inserted_at]
  end

  # ── Chunking (RAG) ──

  # Leading per-page marker written at extraction time. The physical PDF sheet
  # is always present; the rulebook's printed page is appended when detected:
  #   "===== SHEET 15 PAGE 12 =====" (printed page 12 lives on sheet 15)
  #   "===== SHEET 4 ====="          (front matter / printed page unknown)
  @page_marker ~r/\A=+\s*SHEET\s+(\d+)(?:\s+PAGE\s+(\d+))?\s*=+[ \t]*\r?\n?/i

  @doc """
  Splits a leading page marker off a page segment. Returns
  `{sheet, printed, rest}` where `sheet` is the physical PDF sheet number,
  `printed` is the rulebook's printed page number (or `nil` when unknown), and
  `rest` is the page text. Returns `nil` if the segment has no marker (legacy
  documents extracted before numbering).
  """
  def split_page_marker(segment) do
    case Regex.run(@page_marker, segment) do
      [matched, sheet, printed] ->
        {String.to_integer(sheet), String.to_integer(printed),
         String.replace_prefix(segment, matched, "")}

      [matched, sheet] ->
        {String.to_integer(sheet), nil, String.replace_prefix(segment, matched, "")}

      _ ->
        nil
    end
  end

  @doc """
  Citation label + number for a page from its `{sheet, printed}` pair: the
  printed page when known ("Page 12"), else the physical sheet ("Sheet 4").
  """
  def page_label(sheet, printed) do
    if printed, do: {"Page", printed}, else: {"Sheet", sheet}
  end

  @doc """
  Prefixes each page string with a durable, visible marker. When the printed
  page number can be detected (footer/header) we anchor to it; otherwise the
  physical sheet number is used (front matter, or low-confidence docs). Takes a
  list of per-page text strings (physical order) and returns the joined,
  marked-up text. Used by both the upload and download extraction paths.
  """
  def number_pages(pages) do
    pages |> paginate() |> rebuild_full_text()
  end

  @doc """
  Turns a list of raw per-page text strings (physical order) into first-class
  page maps: `%{index:, sheet:, printed:, text:}`. `printed` is the detected
  rulebook page number (nil when unknown). This is the source-of-truth shape
  stored in `Document.pages`.
  """
  def paginate(raw_pages) do
    printed_by_sheet = assign_printed(raw_pages)

    raw_pages
    |> Enum.with_index(1)
    |> Enum.map(fn {text, sheet} ->
      %{index: sheet - 1, sheet: sheet, printed: Map.get(printed_by_sheet, sheet), text: text}
    end)
  end

  @doc """
  Recomputes printed page numbers for an already-stored document from each
  page's original extracted text (where the footers live), preserving any
  cleaned/hand-edited bodies. Use to re-apply improved detection to docs
  ingested under older logic without re-downloading. Re-chunks via
  `update_document/2` since `full_text` changes.
  """
  def repaginate_document(%Document{} = doc) do
    ordered = Enum.sort_by(doc.pages, & &1.index)
    raw = Enum.map(ordered, & &1.text)
    recomputed = paginate(raw)

    new_pages =
      Enum.zip(ordered, recomputed)
      |> Enum.map(fn {p, r} -> %{page_attrs(p) | printed: r.printed} end)

    update_document(doc, %{
      pages: new_pages,
      full_text: rebuild_full_text(new_pages),
      printed_offset: detect_printed_offset(raw)
    })
  end

  @doc """
  Manual fallback for when automatic printed-page detection fails: the user
  tells us which physical sheet carries printed "Page 1", and we number every
  page from there. Sheet `page_one_sheet` becomes printed 1, the next sheet 2,
  and so on; sheets *before* the anchor are front matter and stay unnumbered
  (`printed: nil`), matching how detected front matter is handled.

  Returns the page maps with their `printed` field rewritten. Bodies (`text`,
  `cleaned`) are untouched. `page_one_sheet < 1` is clamped to 1.
  """
  def assign_printed_from_anchor(pages, page_one_sheet) when is_integer(page_one_sheet) do
    anchor = max(page_one_sheet, 1)

    Enum.map(pages, fn p ->
      printed = if p.sheet >= anchor, do: p.sheet - anchor + 1, else: nil
      Map.put(p, :printed, printed)
    end)
  end

  @doc """
  Persists manual page numbering on a stored document: numbers every page from
  the given page-1 anchor sheet (see `assign_printed_from_anchor/2`), preserving
  each page's text/cleaned body, and re-chunks so citations pick up the new page
  numbers. Returns the `update_document/2` result.
  """
  def set_printed_anchor(%Document{} = doc, page_one_sheet) when is_integer(page_one_sheet) do
    pages =
      doc.pages
      |> Enum.sort_by(& &1.index)
      |> assign_printed_from_anchor(page_one_sheet)
      |> Enum.map(&page_attrs/1)

    update_document(doc, %{pages: pages, full_text: rebuild_full_text(pages)})
  end

  @doc """
  Replaces one page's extracted text and provenance (used by a single-page
  re-extraction). `fields` is `%{text:, confidence:, lane:, source:}`. Clears any
  cleaned/edited body (the fresh extraction supersedes it), preserves the page's
  printed number, rebuilds full_text, and re-chunks via `update_document/2`.

  Re-fetches the document by id before rebuilding the pages array (mirrors
  `set_page_cleaned/3`) rather than trusting the caller's in-memory `doc`. A
  single-page re-extraction runs through a strong model + critic and can take
  minutes; a `doc` loaded before that wait is a stale snapshot, and rebuilding
  the whole pages array from it would silently clobber any concurrent per-page
  write (e.g. the cleanup worker's `set_page_cleaned/3`) that landed in the
  meantime. Only `doc.id` from the passed-in struct is used.
  """
  def replace_page(%Document{} = doc, index, fields) do
    doc = get_document!(doc.id)

    pages =
      doc.pages
      |> Enum.sort_by(& &1.index)
      |> Enum.map(fn p ->
        if p.index == index do
          %{
            page_attrs(p)
            | text: fields.text,
              cleaned: nil,
              confidence: fields.confidence,
              lane: fields.lane,
              source: fields.source,
              # A re-extract is a fresh decision: overwrite the detail (Map.get so
              # callers passing only the core fields clear stale signals to nil).
              gate_agreement: Map.get(fields, :gate_agreement),
              gate_coverage: Map.get(fields, :gate_coverage),
              escalated: Map.get(fields, :escalated),
              critic_rounds: Map.get(fields, :critic_rounds),
              residual_defects: Map.get(fields, :residual_defects)
          }
        else
          page_attrs(p)
        end
      end)

    update_document(doc, %{pages: pages, full_text: rebuild_full_text(pages)})
  end

  @doc """
  Parses an existing marker-delimited `full_text` blob back into page maps.
  Handles legacy blobs without markers (positional sheet numbers, no printed
  page). Used when persisting hand-edited text and when backfilling.
  """
  def pages_from_full_text(text) do
    segments =
      text
      |> String.split("\f")
      |> Enum.reject(&(String.trim(&1) == ""))

    if Enum.any?(segments, &(split_page_marker(&1) != nil)) do
      segments
      |> Enum.flat_map(fn seg ->
        case split_page_marker(seg) do
          {sheet, printed, body} -> [%{sheet: sheet, printed: printed, text: body}]
          nil -> []
        end
      end)
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> Map.put(p, :index, i) end)
    else
      segments
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        %{index: i, sheet: i + 1, printed: nil, text: text}
      end)
    end
  end

  @doc """
  Removes the printed page number from a page body when it appears as an
  isolated header/footer line (bare "12", "Page 12", or a decorated "— 12 —").
  The number is stored separately on the page (`printed`), so keeping it in the
  body is duplicate clutter that also pollutes retrieval/quoting.

  Only the first/last few non-empty lines are considered, and only lines that
  resolve to exactly `printed` are dropped — a legitimate number inside a rule
  ("place 12 cubes") is never touched. No-op when `printed` is nil.
  """
  def strip_printed_number(text, nil), do: text

  def strip_printed_number(text, printed) when is_integer(printed) do
    lines = String.split(text, "\n")

    nonempty = for {l, i} <- Enum.with_index(lines), String.trim(l) != "", do: i
    zone = MapSet.new(Enum.take(nonempty, 3) ++ Enum.take(nonempty, -3))

    lines
    |> Enum.with_index()
    |> Enum.reject(fn {line, i} ->
      MapSet.member?(zone, i) and line_page_number(String.trim(line)) == printed
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.join("\n")
  end

  @doc """
  Effective page text used everywhere downstream: the cleaned/edited working
  copy if present, else the original. Accepts `Document.Page` structs or plain
  maps (a missing `:cleaned` key is treated as nil).
  """
  def effective_page_text(p) do
    if is_binary(Map.get(p, :cleaned)), do: p.cleaned, else: p.text || ""
  end

  @doc """
  Rebuilds the marker-delimited `full_text` blob from page structs/maps using
  each page's effective text (the derived cache consumed by the LLM, search,
  cheat sheet and chunker).
  """
  def rebuild_full_text(pages) do
    Enum.map_join(pages, "", fn p ->
      marker = if p.printed, do: "SHEET #{p.sheet} PAGE #{p.printed}", else: "SHEET #{p.sheet}"
      "\f===== #{marker} =====\n" <> effective_page_text(p)
    end)
  end

  @doc """
  The dominant physical-sheet→printed-page offset for a document (the
  `sheet - printed` of the largest consistent run), or nil when no run clears
  the support threshold. Kept for the stored `documents.printed_offset`
  diagnostic; page numbering itself uses the per-segment `assign_printed/1`.
  """
  def detect_printed_offset(pages) do
    case offset_runs(page_candidates(pages), length(pages)) do
      [] -> nil
      runs -> runs |> Enum.max_by(fn {_offset, _lo, _hi, n} -> n end) |> elem(0)
    end
  end

  # Maps each physical sheet to its printed page number, handling rulebooks
  # whose printed numbering shifts partway (unnumbered inserts, fold-outs, front
  # matter). Strategy: find consistent "runs" — sets of pages sharing one
  # `sheet - printed` offset (a single offset means printed advances exactly
  # with the sheet, i.e. a monotonic +1 sequence). The best-supported run claims
  # its sheet span first (interpolating numbers for unlabelled pages inside it);
  # weaker runs fill the sheets the strong one didn't cover.
  #
  # The outermost run also extrapolates past its observed pages to the document
  # edges, so unlabelled front/back matter inherits the offset (e.g. a footer
  # "3" detected on sheet 3 implies sheets 1-2 are pages 1-2). The `printed >= 1`
  # guard keeps this honest: genuine unnumbered front matter (where page 1 only
  # starts several sheets in, i.e. a positive offset) extrapolates to page 0 or
  # below and is left nil. Interior gaps between two *different* offsets are NOT
  # filled — those are the unnumbered inserts that caused the shift.
  defp assign_printed(raw_pages) do
    n = length(raw_pages)

    case offset_runs(page_candidates(raw_pages), n) do
      [] ->
        %{}

      runs ->
        min_lo = runs |> Enum.map(fn {_o, lo, _hi, _n} -> lo end) |> Enum.min()
        max_hi = runs |> Enum.map(fn {_o, _lo, hi, _n} -> hi end) |> Enum.max()

        runs
        # Stretch only the leading run back to sheet 1 and the trailing run out
        # to the last sheet; interior runs keep their observed span.
        |> Enum.map(fn {offset, lo, hi, support} ->
          lo = if lo == min_lo, do: 1, else: lo
          hi = if hi == max_hi, do: n, else: hi
          {offset, lo, hi, support}
        end)
        # Strongest run first so it wins any sheet-span overlap.
        |> Enum.sort_by(fn {_offset, _lo, _hi, support} -> -support end)
        |> Enum.reduce(%{}, fn {offset, lo, hi, _support}, acc ->
          Enum.reduce(lo..hi, acc, fn sheet, acc ->
            printed = sheet - offset

            if printed >= 1 and not Map.has_key?(acc, sheet),
              do: Map.put(acc, sheet, printed),
              else: acc
          end)
        end)
    end
  end

  # `[{sheet, printed_candidate}]` for every sheet that yielded a number.
  defp page_candidates(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, sheet} ->
      case page_number_candidate(text) do
        nil -> []
        num -> [{sheet, num}]
      end
    end)
  end

  # Groups candidates by `sheet - printed` offset and keeps the groups with
  # enough corroboration to trust over raw sheet numbers. Each surviving group
  # is `{offset, min_sheet, max_sheet, support}` — a run spanning those sheets.
  # A lone candidate (support 1) is treated as noise.
  defp offset_runs(candidates, page_count) do
    min_support = max(2, div(page_count, 10))

    candidates
    |> Enum.group_by(fn {sheet, num} -> sheet - num end, fn {sheet, _num} -> sheet end)
    |> Enum.map(fn {offset, sheets} ->
      {offset, Enum.min(sheets), Enum.max(sheets), length(sheets)}
    end)
    |> Enum.filter(fn {_offset, _lo, _hi, n} -> n >= min_support end)
  end

  # Best-guess printed page number for one page: scan the first and last few
  # non-empty lines (where headers/footers live) for a bare/decorated integer,
  # preferring the footer. OCR digit look-alikes (1↔l/I, 0↔O) are repaired on
  # mostly-numeric lines first. Returns the integer or nil.
  defp page_number_candidate(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Footer lines first (most reliable), then header lines.
    candidates = Enum.reverse(Enum.take(lines, -5)) ++ Enum.take(lines, 5)

    Enum.find_value(candidates, &line_page_number/1)
  end

  defp line_page_number(line) do
    norm = ocr_normalize(line)

    cond do
      # bare number ("12"), tolerating the original being a short numeric token
      n = match_int(norm, ~r/^(\d{1,3})$/) -> n
      # "Page 12", "p. 12", "pg 12"
      n = match_int(norm, ~r/^(?:page|pg|p\.?)\s*(\d{1,3})\b/i) -> n
      # decorated footer: "— 12 —", "| 12 |", "• 12"
      n = match_int(norm, ~r/^[—\-–|•·*~_\s]*(\d{1,3})[—\-–|•·*~_\s]*$/) -> n
      # "12 / 130", "12 of 130"
      n = match_int(norm, ~r/^(\d{1,3})\s*(?:\/|of)\s*\d{1,3}$/i) -> n
      true -> nil
    end
  end

  defp match_int(str, re) do
    case Regex.run(re, str) do
      [_, d] -> String.to_integer(d)
      _ -> nil
    end
  end

  # Repair the common OCR confusions that turn page-number digits into letters,
  # but only on short, mostly-numeric lines so real footer words aren't mangled.
  # Limited to the high-confidence swaps (l/I/|→1, O/o/Q→0); ambiguous ones like
  # S→5/B→8 are skipped because they corrupt real words (e.g. "SOS").
  defp ocr_normalize(line) do
    if numeric_ish?(line) do
      line
      |> String.replace(~r/[OoQ]/, "0")
      |> String.replace(~r/[lI|!]/, "1")
    else
      line
    end
  end

  defp numeric_ish?(line) do
    chars = line |> String.replace(~r/\s/, "") |> String.graphemes()

    case chars do
      [] -> false
      _ -> Enum.count(chars, &(&1 =~ ~r/[0-9OoQlI|!]/)) * 2 >= length(chars)
    end
  end

  def chunk_document(%Document{} = doc) do
    # Prefer first-class pages; fall back to parsing the legacy full_text blob
    # for documents not yet backfilled.
    # Each page yields {page_num, text}. page_num is the printed page when known,
    # else the physical sheet — but the chunk marker is ALWAYS "[Page N]" (never
    # "[Sheet N]"): the LLM prompt and the cited-page parser only understand
    # "[Page N]", so a "[Sheet N]" marker (emitted whenever printed numbers
    # weren't detected, e.g. OCR docs) left the model unable to cite a page at
    # all — and page citation is a hard requirement.
    pages =
      case doc.pages do
        [_ | _] = doc_pages ->
          Enum.map(doc_pages, fn p ->
            # Use the effective text (cleaned/edited copy if present, else the
            # original) so rulebook cleanup actually reaches retrieval, not just
            # the displayed text and cheat sheet.
            {p.printed || p.sheet, effective_page_text(p)}
          end)

        _ ->
          segments = String.split(doc.full_text, "\f")

          if Enum.any?(segments, &(split_page_marker(&1) != nil)) do
            segments
            |> Enum.map(&split_page_marker/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.map(fn {sheet, printed, text} -> {printed || sheet, text} end)
          else
            segments
            |> Enum.with_index(1)
            |> Enum.map(fn {text, idx} -> {idx, text} end)
          end
      end

    chunks_with_meta =
      pages
      |> Enum.flat_map(fn {page_num, page_text} ->
        page_text
        |> split_into_chunks(500)
        |> Enum.map(fn chunk_text ->
          %{content: "[Page #{page_num}]\n#{String.trim(chunk_text)}", page_number: page_num}
        end)
      end)
      |> Enum.with_index()
      |> Enum.map(fn {%{content: text, page_number: pn}, idx} ->
        section = detect_section_label(text)
        refs = detect_cross_references(text)
        {text, idx, section, refs, pn}
      end)

    # Batch-insert all chunks in one query (a big rulebook is hundreds of chunks;
    # one INSERT per row blocked the upload request on round-trips). insert_all
    # skips changeset autotimestamps, so set them explicitly.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(chunks_with_meta, fn {text, idx, section, refs, pn} ->
        %{
          document_id: doc.id,
          chunk_index: idx,
          content: text,
          section_label: section,
          references_section: refs,
          page_number: pn,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Clear the old chunks and insert the new ones atomically — a failed insert
    # (e.g. a DB-level rejection partway through) must not leave the document
    # with zero chunks. Repo.transaction re-raises on error after rolling back.
    Repo.transaction(fn ->
      Repo.delete_all(from c in Chunk, where: c.document_id == ^doc.id)
      if rows != [], do: Repo.insert_all(Chunk, rows)
    end)

    # Enqueue embedding generation as Oban job (skip in test)
    unless testing?() do
      %{document_id: doc.id}
      |> RuleMaven.Workers.EmbedChunksWorker.new()
      |> Oban.insert()
    end
  end

  # Backward compat alias
  defdelegate chunk_source(source), to: __MODULE__, as: :chunk_document

  @doc "True when the document has any chunks (embedded or awaiting embedding)."
  def document_chunked?(doc_id) do
    Repo.exists?(from(c in Chunk, where: c.document_id == ^doc_id))
  end

  def retrieve_chunks(%Game{} = game, question, limit \\ 6) do
    retrieve_chunks_for_games([game.id], question, limit: limit)
  end

  @doc """
  Semantic chunk retrieval. Pass `:embedding` to reuse a question vector already
  computed upstream (avoids a redundant embedding API call); otherwise embeds
  here. `:limit` caps returned chunks (default 6).
  """
  def retrieve_chunks_for_games(game_ids, question, opts \\ []) when is_list(game_ids) do
    limit = Keyword.get(opts, :limit, 6)
    base_game_id = Keyword.get(opts, :base_game_id, List.first(game_ids))

    embed_result =
      case Keyword.get(opts, :embedding) do
        nil -> RuleMaven.Embed.embed(question)
        vec -> {:ok, vec}
      end

    # Try semantic retrieval via pgvector
    case embed_result do
      {:ok, question_vec} ->
        chunks =
          Repo.all(
            from c in Chunk,
              join: d in Document,
              on: c.document_id == d.id,
              join: g in Game,
              on: g.id == d.game_id,
              where:
                d.game_id in ^game_ids and d.status == "published" and
                  not is_nil(c.embedding),
              order_by:
                fragment(
                  "cosine_distance(?, ?::vector)",
                  c.embedding,
                  ^Pgvector.new(question_vec)
                ),
              # Over-fetch so dedup can drop near-duplicates and still fill the limit.
              limit: ^(limit * 2),
              select: %{
                id: c.id,
                content: c.content,
                section_label: c.section_label,
                references_section: c.references_section,
                embedding: c.embedding,
                document_id: d.id,
                label: d.label,
                kind: d.kind,
                game_id: d.game_id,
                game_name: g.name
              }
          )

        if chunks == [] do
          published_full_text_fallback(game_ids)
        else
          chunks
          |> dedup_near_duplicates(base_game_id)
          |> Enum.take(limit)
          |> pull_referenced_chunks(game_ids)
          |> Enum.map(&Map.drop(&1, [:embedding]))
        end

      {:error, _} ->
        # Fallback to keyword overlap across all games
        keyword_retrieve_multi(game_ids, question, limit)
    end
  end

  # Greedy near-duplicate collapse. Chunks arrive relevance-ordered; each is kept
  # unless it's ≥ @dup_threshold cosine-similar to one or more already-kept
  # chunks, in which case the WHOLE collided cluster (the incoming chunk plus
  # every match — similarity isn't transitive, so a chunk can match more than
  # one already-kept chunk at once) collapses to a single survivor: the most
  # authoritative one (kind authority, then base game beats expansion). Guides
  # restating the rulebook and expansions reprinting base rules stop crowding
  # the retrieval budget.
  @dup_threshold 0.97

  defp dedup_near_duplicates(chunks, base_game_id) do
    Enum.reduce(chunks, [], fn chunk, kept ->
      case Enum.split_with(kept, &(cosine_sim(&1.embedding, chunk.embedding) >= @dup_threshold)) do
        {[], _} ->
          kept ++ [chunk]

        {matches, _rest} ->
          winner = pick_authoritative([chunk | matches], base_game_id)
          # Preserve relevance order: the survivor takes the EARLIEST position
          # among the colliding cluster's members in `kept`, rather than being
          # appended to the end. Appending would push a top-ranked cluster's
          # survivor past `limit` in the caller's `Enum.take(limit)` and
          # silently drop it, as well as scrambling result ordering.
          matched_indices = for {k, i} <- Enum.with_index(kept), k in matches, do: i
          insert_at = Enum.min(matched_indices)

          kept
          |> Enum.reject(&(&1 in matches))
          |> List.insert_at(insert_at, winner)
      end
    end)
  end

  defp pick_authoritative(candidates, base_game_id) do
    Enum.min_by(candidates, fn c ->
      {RuleMaven.Games.Document.authority(c.kind), if(c.game_id == base_game_id, do: 0, else: 1)}
    end)
  end

  defp cosine_sim(a, b) do
    a = Pgvector.to_list(a)
    b = Pgvector.to_list(b)
    dot = Enum.zip_with(a, b, &*/2) |> Enum.sum()
    na = :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1))))
    nb = :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))
    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end

  # Last-resort retrieval context when semantic + keyword search find nothing
  # (e.g. embeddings not yet generated). Invariants the per-document fallbacks
  # got wrong:
  #   1. PUBLISHED ONLY — `document_full_text/1` ignored status, so a
  #      `pending_review`/`rejected` rulebook leaked into answers, bypassing the
  #      whole approval gate.
  #   2. CAPPED — dumping an entire (multi-game) rulebook could overflow the
  #      model's context window; budget the text instead.
  #   3. PER-DOCUMENT ATTRIBUTION — merging every published doc's full_text
  #      into one blob attributed to a single "representative" document was
  #      wrong whenever more than one doc was in play (wrong label/kind on the
  #      combined content, and a doc with no full_text still "borrowed"
  #      attribution for someone else's text). Return one entry per document
  #      instead, each labeled with its own metadata, with the shared budget
  #      split evenly (floor) across the contributing docs.
  @fallback_char_budget 12_000

  defp published_full_text_fallback(game_ids) do
    docs =
      Repo.all(
        from d in Document,
          join: g in Game,
          on: g.id == d.game_id,
          where: d.game_id in ^game_ids and d.status == "published",
          order_by: [asc: d.game_id, asc: d.id],
          select: %{
            full_text: d.full_text,
            document_id: d.id,
            label: d.label,
            kind: d.kind,
            game_id: d.game_id,
            game_name: g.name
          }
      )
      |> Enum.filter(&(&1.full_text not in [nil, ""]))

    case docs do
      [] ->
        []

      _ ->
        per_doc_budget = div(@fallback_char_budget, length(docs))

        Enum.map(docs, fn d ->
          %{
            content: String.slice(String.trim(d.full_text), 0, per_doc_budget),
            document_id: d.document_id,
            label: d.label,
            kind: d.kind,
            game_id: d.game_id,
            game_name: d.game_name
          }
        end)
    end
  end

  defp keyword_retrieve_multi(game_ids, question, limit) do
    chunks =
      Repo.all(
        from c in Chunk,
          join: d in Document,
          on: c.document_id == d.id,
          join: g in Game,
          on: g.id == d.game_id,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{
            id: c.id,
            content: c.content,
            section_label: c.section_label,
            references_section: c.references_section,
            document_id: d.id,
            label: d.label,
            kind: d.kind,
            game_id: d.game_id,
            game_name: g.name
          }
      )

    if chunks == [] do
      published_full_text_fallback(game_ids)
    else
      question_words = tokenize(question)

      scored =
        chunks
        |> Enum.map(fn chunk ->
          score = relevance_score(chunk.content, question_words)
          {score, chunk}
        end)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.take(limit)

      if Enum.all?(scored, fn {score, _} -> score == 0 end) do
        published_full_text_fallback(game_ids)
      else
        top_chunks = Enum.map(scored, fn {_, c} -> c end)
        top_chunks |> pull_referenced_chunks(game_ids)
      end
    end
  end

  # ── Chunk helpers ──

  defp split_into_chunks(nil, _target_words), do: []
  defp split_into_chunks("", _target_words), do: []

  defp split_into_chunks(text, target_words) do
    paragraphs = String.split(text, ~r{\n\s*\n})

    paragraphs
    |> Enum.reduce({[], []}, fn para, {current, acc} ->
      current_words = current |> Enum.join(" ") |> word_count()

      if current_words + word_count(para) > target_words and current != [] do
        {[para], [Enum.join(current, "\n\n") | acc]}
      else
        {current ++ [para], acc}
      end
    end)
    |> then(fn {current, acc} ->
      if current != [], do: [Enum.join(current, "\n\n") | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp word_count(text), do: text |> String.split(~r/\s+/) |> length()

  defp tokenize(text) do
    stop_words =
      ~w(the a an and or but in on at to for of with by from is are was were be been being have has had do does did will would can could should may might i you he she it we they me him her us them my your his its our their this that these those)

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 in stop_words or String.length(&1) < 2))
    |> Enum.uniq()
  end

  defp relevance_score(chunk_text, question_words) do
    chunk_words = tokenize(chunk_text)
    overlap = Enum.count(question_words, &(&1 in chunk_words))

    phrase_bonus =
      if String.contains?(
           String.downcase(chunk_text),
           String.downcase(Enum.join(question_words, " "))
         ),
         do: 5,
         else: 0

    overlap + phrase_bonus
  end

  # ── Cross-reference detection ──

  # Regex patterns for cross-references like "see Section 4.3", "see rule 7.2", "see 4.1"
  @ref_pattern ~r{(?:see|refer to|reference to|per|according to)\s+(?:Section\s+|Rule\s+|§\s*)?(\d+(?:\.\d+)*)}i

  defp detect_cross_references(text) do
    @ref_pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_, ref] -> ref end)
    |> Enum.uniq()
  end

  # Section label patterns: "SECTION 4: Title", "4.1 Title:", "Section 7: Full Combat Rules", etc.
  @section_pattern_head ~r/(?:SECTION|Section|Chapter)\s+(\d+(?:\.\d+)*)/i
  @section_pattern_inline ~r/^(\d+(?:\.\d+))\s/m

  defp detect_section_label(text) do
    case Regex.run(@section_pattern_head, text) do
      [_, num] -> num
      nil -> detect_inline_section(text)
    end
  end

  defp detect_inline_section(text) do
    case Regex.run(@section_pattern_inline, text) do
      [_, num] -> num
      nil -> nil
    end
  end

  defp pull_referenced_chunks(initial_chunks, game_ids) do
    # Collect all unique section labels referenced by retrieved chunks
    referenced_labels =
      initial_chunks
      |> Enum.flat_map(&(&1.references_section || []))
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    if referenced_labels == [] do
      initial_chunks
    else
      # Fetch chunks that belong to referenced sections
      referenced_chunks =
        Repo.all(
          from c in Chunk,
            join: d in Document,
            on: c.document_id == d.id,
            join: g in Game,
            on: g.id == d.game_id,
            where:
              d.game_id in ^game_ids and d.status == "published" and
                c.section_label in ^referenced_labels,
            select: %{
              id: c.id,
              content: c.content,
              section_label: c.section_label,
              references_section: c.references_section,
              document_id: d.id,
              label: d.label,
              kind: d.kind,
              game_id: d.game_id,
              game_name: g.name
            }
        )

      # Deduplicate by content (avoid adding same chunk twice)
      existing_contents = MapSet.new(initial_chunks, & &1.content)

      extra =
        Enum.reject(referenced_chunks, fn c ->
          MapSet.member?(existing_contents, c.content)
        end)

      initial_chunks ++ extra
    end
  end

  # ---------------------------------------------------------------------------
  # Categories
  # ---------------------------------------------------------------------------

  def list_game_categories(%Game{} = game) do
    Repo.all(from c in GameCategory, where: c.game_id == ^game.id, order_by: c.name)
  end

  def replace_game_categories(%Game{} = game, cat_list) do
    Repo.delete_all(from c in GameCategory, where: c.game_id == ^game.id)

    Enum.each(cat_list, fn %{name: name, description: desc} ->
      text = "#{name}: #{desc}"

      embedding =
        case RuleMaven.Embed.embed(text) do
          {:ok, vec} -> Pgvector.new(vec)
          _ -> nil
        end

      %GameCategory{}
      |> GameCategory.changeset(%{
        game_id: game.id,
        name: name,
        description: desc,
        name_embedding: embedding
      })
      |> Repo.insert!()
    end)

    # Categories changed (and deleting the old rows dropped their question tags),
    # so re-tag every question against the new taxonomy.
    retag_all_questions(game)

    :ok
  end

  def delete_game_category(id) do
    case Repo.get(GameCategory, id) do
      nil -> :ok
      cat -> Repo.delete(cat)
    end
  end

  def tag_question(question_log_id, game_id) do
    q = Repo.get!(QuestionLog, question_log_id)

    if is_nil(q.question_embedding) do
      :skipped
    else
      q_vec = q.question_embedding

      top2 =
        Repo.all(
          from c in GameCategory,
            where: c.game_id == ^game_id and not is_nil(c.name_embedding),
            order_by: fragment("cosine_distance(?, ?::vector)", c.name_embedding, ^q_vec),
            limit: 2,
            select: {c.id, fragment("cosine_distance(?, ?::vector)", c.name_embedding, ^q_vec)}
        )
        # Category-name vs question-phrasing embeddings rarely land below 0.5, so
        # that bar left many questions untagged. 0.62 still rejects unrelated
        # categories while catching genuine-but-loose matches.
        |> Enum.filter(fn {_, dist} -> dist <= 0.62 end)

      Enum.each(top2, fn {cat_id, _} ->
        %QuestionCategoryTag{}
        |> QuestionCategoryTag.changeset(%{
          question_log_id: question_log_id,
          game_category_id: cat_id
        })
        |> Repo.insert(on_conflict: :nothing)
      end)

      # Let an open Q&A page show the new pills without a remount.
      Phoenix.PubSub.broadcast(
        RuleMaven.PubSub,
        "game:#{game_id}",
        {:question_tagged, question_log_id}
      )

      :ok
    end
  end

  def retag_all_questions(%Game{} = game) do
    ids =
      Repo.all(
        from q in QuestionLog,
          where:
            q.game_id == ^game.id and q.refused == false and not is_nil(q.question_embedding),
          select: q.id
      )

    Enum.each(ids, fn id ->
      RuleMaven.Workers.TagQuestionWorker.enqueue(id, game.id)
    end)

    length(ids)
  end

  def categories_for_questions([]), do: %{}

  def categories_for_questions(question_log_ids) do
    tags =
      Repo.all(
        from t in QuestionCategoryTag,
          join: c in assoc(t, :game_category),
          where: t.question_log_id in ^question_log_ids,
          select: {t.question_log_id, c}
      )

    Enum.reduce(tags, %{}, fn {qid, cat}, acc ->
      Map.update(acc, qid, [cat], &[cat | &1])
    end)
  end

  def questions_for_category(category_id, opts \\ []) do
    community_only = Keyword.get(opts, :community_only, true)

    query =
      from q in QuestionLog,
        join: t in QuestionCategoryTag,
        on: t.question_log_id == q.id and t.game_category_id == ^category_id,
        where: q.refused == false,
        order_by: [desc: q.inserted_at]

    query =
      if community_only, do: from(q in query, where: q.visibility == "community"), else: query

    Repo.all(query)
  end

  def get_user_community_vote(question_log_id, user_id) do
    Repo.get_by(QuestionVote, question_log_id: question_log_id, user_id: user_id)
  end

  def set_community_vote(question_log_id, user_id, value, admin? \\ false) do
    q = Repo.get(QuestionLog, question_log_id)

    cond do
      # Reject unknown values up front: do_set_community_vote uses insert!/update!,
      # so an out-of-range value (e.g. a forged event) would raise mid-write.
      value not in ["up", "down"] -> {:error, :invalid_value}
      is_nil(q) -> {:error, :not_found}
      # Admins may vote (and unvote) their own rows — useful for seeding/curation.
      # Everyone else is blocked from self-voting.
      q.user_id == user_id and not admin? -> {:error, :self_vote}
      not votable?(q) -> {:error, :not_votable}
      true -> do_set_community_vote(q, user_id, value)
    end
  end

  # A row is votable only if it can actually surface to other users: community
  # rows (browse/FAQ) or pooled rows (served as fast-path answers). This blocks
  # voting on rows that never surface — e.g. arbitrary private rows by id (IDOR).
  defp votable?(%QuestionLog{} = q) do
    q.visibility == "community" or q.pooled
  end

  defp do_set_community_vote(%QuestionLog{id: question_log_id}, user_id, value) do
    existing = get_user_community_vote(question_log_id, user_id)
    weight = RuleMaven.Games.Trust.vote_weight(Repo.get(RuleMaven.Users.User, user_id))

    result =
      cond do
        existing && existing.value == value ->
          Repo.delete(existing)
          nil

        existing ->
          existing
          |> QuestionVote.changeset(%{value: value, weight: weight})
          |> Repo.update!()

          value

        true ->
          # Upsert on the (question_log_id, user_id) unique index so a concurrent
          # double-submit updates the existing vote instead of raising.
          %QuestionVote{}
          |> QuestionVote.changeset(%{
            question_log_id: question_log_id,
            user_id: user_id,
            value: value,
            weight: weight
          })
          |> Repo.insert!(
            on_conflict: {:replace, [:value, :weight, :updated_at]},
            conflict_target: [:question_log_id, :user_id]
          )

          value
      end

    # Recompute the row's trust_score and the answer author's reputation so
    # ranking/promotion react immediately.
    if q = Repo.get(QuestionLog, question_log_id) do
      RuleMaven.Games.Trust.recompute_trust(q)
      if q.user_id, do: RuleMaven.Games.Trust.recompute_reputation(q.user_id)
    end

    result
  end

  def community_vote_maps(question_log_ids, user_id) do
    all_votes =
      Repo.all(
        from v in QuestionVote,
          where: v.question_log_id in ^question_log_ids
      )

    user_votes_rows =
      Repo.all(
        from v in QuestionVote,
          where: v.question_log_id in ^question_log_ids and v.user_id == ^user_id
      )

    counts =
      Enum.reduce(all_votes, %{}, fn v, acc ->
        acc
        |> Map.update(v.question_log_id, %{up: 0, down: 0}, & &1)
        |> update_in([v.question_log_id, String.to_atom(v.value)], &(&1 + 1))
      end)

    user_votes = Map.new(user_votes_rows, &{&1.question_log_id, &1.value})

    {counts, user_votes}
  end

  # ── Per-user answer favorites ──
  #
  # Unlike the QuestionLog.favorited boolean (the asker pinning their own private
  # thread), this lets any user favorite an answer that surfaces to them —
  # community/pool rows authored by someone else. State is per (user, answer).

  @doc """
  Toggle a user's favorite on an answer row. Returns {:ok, true} when now
  favorited, {:ok, false} when removed. Only rows that actually surface to other
  users (community or pooled) are favoritable, blocking IDOR on private rows.
  """
  def toggle_answer_favorite(user_id, question_log_id)
      when is_integer(user_id) and is_integer(question_log_id) do
    case Repo.get(QuestionLog, question_log_id) do
      nil ->
        {:error, :not_found}

      %QuestionLog{} = q ->
        if q.visibility == "community" or q.pooled do
          do_toggle_answer_favorite(user_id, question_log_id)
        else
          {:error, :not_favoritable}
        end
    end
  end

  defp do_toggle_answer_favorite(user_id, question_log_id) do
    case Repo.get_by(AnswerFavorite, user_id: user_id, question_log_id: question_log_id) do
      nil ->
        %AnswerFavorite{}
        |> AnswerFavorite.changeset(%{user_id: user_id, question_log_id: question_log_id})
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:user_id, :question_log_id]
        )

        {:ok, true}

      %AnswerFavorite{} = af ->
        Repo.delete(af)
        {:ok, false}
    end
  end

  @doc "MapSet of answer (question_log) ids the user has favorited, among the given ids."
  def favorited_answer_ids(user_id, question_log_ids)
      when is_integer(user_id) and is_list(question_log_ids) do
    Repo.all(
      from af in AnswerFavorite,
        where: af.user_id == ^user_id and af.question_log_id in ^question_log_ids,
        select: af.question_log_id
    )
    |> MapSet.new()
  end
end
