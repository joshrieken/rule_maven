defmodule RuleMaven.Games do
  @moduledoc """
  The Games context.
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo

  alias RuleMaven.Games.Game
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Games.QuestionVote
  alias RuleMaven.Games.GameCategory
  alias RuleMaven.Games.QuestionCategoryTag
  alias RuleMaven.Games.Document
  alias RuleMaven.Games.Chunk
  alias Oban

  # ── Games ──

  def list_games, do: Repo.all(Game)

  def list_games_with_documents do
    # Base games + expansions that have published documents.
    # Returns base games sorted by name.
    base_ids =
      Repo.all(
        from g in Game,
          join: d in Document,
          on: d.game_id == g.id,
          where: d.status == "published",
          where: is_nil(g.parent_game_id),
          distinct: true,
          select: g.id
      )

    Repo.all(from g in Game, where: g.id in ^base_ids)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def list_base_games do
    Repo.all(from g in Game, where: is_nil(g.parent_game_id))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def expansions_for(%Game{} = game) do
    Repo.all(from g in Game, where: g.parent_game_id == ^game.id)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def expansions_with_documents(%Game{} = base_game) do
    Repo.all(
      from g in Game,
        join: d in Document,
        on: d.game_id == g.id,
        where: g.parent_game_id == ^base_game.id,
        where: d.status == "published",
        distinct: true,
        select: g
    )
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def base_game_for(%Game{} = game) do
    if game.parent_game_id do
      Repo.get(Game, game.parent_game_id)
    end
  end

  def get_game!(id), do: Repo.get!(Game, id)

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

  def delete_game(%Game{} = game) do
    Repo.delete_all(from d in Document, where: d.game_id == ^game.id)
    Repo.delete_all(from q in QuestionLog, where: q.game_id == ^game.id)
    Repo.delete(game)
  end

  def delete_all_games do
    Repo.delete_all(Document)
    Repo.delete_all(QuestionLog)
    {count, _} = Repo.delete_all(Game)
    {count, nil}
  end

  def change_game(%Game{} = game, attrs \\ %{}) do
    Game.changeset(game, attrs)
  end

  # ── Documents ──

  def list_documents(%Game{} = game) do
    Repo.all(from d in Document, where: d.game_id == ^game.id)
  end

  def create_document(attrs) do
    # Auto-publish if quality looks good
    status =
      if RuleMaven.Settings.get("auto_approve_documents") != "false" and
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
      {:ok, doc} ->
        chunk_document(doc)

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

    # Too short = garbage
    if String.length(stripped) < 500 do
      false
    else
      # Check ratio of dictionary-like words
      words = String.split(stripped, ~r/\s+/)
      total = length(words)

      if total == 0 do
        false
      else
        # Words that look like English: contain at least one vowel
        valid =
          Enum.count(words, fn w ->
            String.match?(String.downcase(w), ~r/[aeiou]/) and
              String.length(w) >= 2
          end)

        ratio = valid / total
        ratio >= 0.7
      end
    end
  end

  defp testing? do
    Application.get_env(:rule_maven, Oban)[:testing] == :manual
  end

  def get_document!(id), do: Repo.get!(Document, id)

  def update_document(%Document{} = doc, attrs) do
    doc
    |> Document.changeset(attrs)
    |> Repo.update()
  end

  def delete_document(%Document{} = doc) do
    Repo.delete_all(from c in Chunk, where: c.document_id == ^doc.id)
    Repo.delete(doc)
  end

  def document_full_text(%Game{} = game) do
    game
    |> list_documents()
    |> Enum.map_join("\n\n", & &1.full_text)
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

  def question_count(%Game{} = game) do
    Repo.aggregate(from(q in QuestionLog, where: q.game_id == ^game.id), :count)
  end

  def recent_question_count(user_id, since) do
    Repo.aggregate(
      from(q in QuestionLog,
        where: q.user_id == ^user_id and q.inserted_at >= ^since
      ),
      :count
    )
  end

  @doc """
  Finds the most recent root question (no parent) from the given user in the game.
  Excludes the current question_log_id. Returns the parent question's ID, or nil.
  """
  def find_parent_question_id(game_id, user_id, exclude_id) do
    query =
      from q in QuestionLog,
        where: q.game_id == ^game_id,
        where: q.user_id == ^user_id,
        where: is_nil(q.parent_question_id),
        where: q.id != ^exclude_id,
        order_by: [desc: q.inserted_at],
        limit: 1

    case Repo.one(query) do
      %QuestionLog{id: id} -> id
      nil -> nil
    end
  end

  def grouped_questions(%Game{} = game, opts \\ []) do
    all = recent_questions(game, 200, opts)

    # Separate roots (no parent) from followups
    {roots, followups} = Enum.split_with(all, &is_nil(&1.parent_question_id))

    # Group roots by exact question text (same question asked again = history)
    roots_by_text = Enum.group_by(roots, &String.downcase(String.trim(&1.question)))

    # Group followups by parent_question_id
    followups_by_parent = Enum.group_by(followups, & &1.parent_question_id)

    roots_by_text
    |> Enum.map(fn {_key, entries} ->
      sorted =
        entries
        |> Enum.sort(fn a, b ->
          case {a.pinned, b.pinned} do
            {true, false} -> true
            {false, true} -> false
            _ -> NaiveDateTime.compare(a.inserted_at, b.inserted_at) == :gt
          end
        end)

      primary = List.first(sorted)
      history = if length(sorted) > 1, do: tl(sorted), else: []

      # Collect followups for this root (and its history entries)
      all_ids = Enum.map(entries, & &1.id)

      followups =
        all_ids |> Enum.flat_map(&Map.get(followups_by_parent, &1, [])) |> Enum.uniq_by(& &1.id)

      # Sort followups by insertion time
      followups = Enum.sort_by(followups, & &1.inserted_at, NaiveDateTime)

      %{primary: primary, history: history, followups: followups}
    end)
    |> Enum.sort_by(& &1.primary.inserted_at, {:desc, DateTime})
  end

  def toggle_favorite(nil), do: {:error, :not_found}

  def toggle_favorite(%QuestionLog{} = q) do
    q |> QuestionLog.changeset(%{favorited: !q.favorited}) |> Repo.update()
  end

  def pin_question(%QuestionLog{} = q) do
    Repo.update_all(
      from(ql in QuestionLog,
        where:
          ql.game_id == ^q.game_id and
            ql.question == ^q.question and
            ql.pinned == true
      ),
      set: [pinned: false]
    )

    Repo.update(QuestionLog.changeset(q, %{pinned: true}))
  end

  def update_question_visibility(%QuestionLog{} = q, visibility) do
    q
    |> QuestionLog.changeset(%{visibility: visibility})
    |> Repo.update()
  end

  def set_question_visibility(id, visibility) when is_integer(id) do
    Repo.update_all(from(q in QuestionLog, where: q.id == ^id), set: [visibility: visibility])
  end

  def check_rate_limit(nil), do: {:error, "Not logged in."}

  def check_rate_limit(user) do
    alias RuleMaven.Users
    alias RuleMaven.Settings

    if Users.game_master?(user) do
      :ok
    else
      now = DateTime.utc_now()

      daily_count = recent_question_count(user.id, DateTime.add(now, -1, :day))
      weekly_count = recent_question_count(user.id, DateTime.add(now, -7, :day))
      monthly_count = recent_question_count(user.id, DateTime.add(now, -30, :day))

      daily_limit = parse_limit(Settings.get("rate_limit_daily"), 50)
      weekly_limit = parse_limit(Settings.get("rate_limit_weekly"), 200)
      monthly_limit = parse_limit(Settings.get("rate_limit_monthly"), 500)

      cond do
        daily_count >= daily_limit -> {:error, "Daily question limit reached (#{daily_limit})."}
        weekly_count >= weekly_limit -> {:error, "Weekly question limit reached (#{weekly_limit})."}
        monthly_count >= monthly_limit -> {:error, "Monthly question limit reached (#{monthly_limit})."}
        true -> :ok
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
      from q in QuestionLog,
        order_by: [desc: q.inserted_at],
        limit: ^limit,
        preload: [:game, :user]

    query =
      if game_id, do: from(q in query, where: q.game_id == ^game_id), else: query

    query =
      case status do
        "pending" -> from(q in query, where: q.answer == "Thinking...")
        "refused" -> from(q in query, where: q.refused == true)
        "error" -> from(q in query, where: like(q.answer, "⚠️%"))
        "answered" -> from(q in query, where: q.answer != "Thinking..." and q.refused == false and not like(q.answer, "⚠️%"))
        _ -> query
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
  def community_questions(%Game{} = game, _exclude_user_id \\ nil) do
    Repo.all(
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: q.visibility == "community",
        where: is_nil(q.parent_question_id),
        where: q.refused == false,
        order_by: [desc: q.inserted_at],
        limit: 50
    )
  end

  @doc """
  Returns refused (not covered) root questions for a game, filtered by user.
  """
  def refused_questions(%Game{} = game, user_id \\ nil) do
    query =
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: q.refused == true,
        where: is_nil(q.parent_question_id),
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
  Searches questions by text match for a game.
  """
  def search_questions(%Game{} = game, query_text) do
    search_term = "%#{query_text}%"

    Repo.all(
      from q in QuestionLog,
        where: q.game_id == ^game.id,
        where: ilike(q.question, ^search_term),
        order_by: [desc: q.inserted_at],
        limit: 50
    )
  end

  @doc """
  Finds a similar question in the question pool using embedding similarity.
  Returns the matching QuestionLog or nil.
  """
  def find_similar_question_in_pool(game_id, question_embedding, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.08)

    # Canonical answers first (admin-curated), then any non-refused answer
    Repo.one(
      from q in QuestionLog,
        where: q.game_id == ^game_id,
        where: not is_nil(q.question_embedding),
        where: q.refused == false,
        where:
          fragment(
            "cosine_distance(?, ?::vector)",
            q.question_embedding,
            ^Pgvector.new(question_embedding)
          ) <= ^threshold,
        order_by: [
          asc: is_nil(q.canonical_answer),
          asc:
            fragment(
              "cosine_distance(?, ?::vector)",
              q.question_embedding,
              ^Pgvector.new(question_embedding)
            )
        ],
        limit: 1
    )
  end

  @doc """
  Returns question threads (root questions with their followups) grouped by game,
  suitable for admin review and consolidation.
  """
  def question_threads(%Game{} = game) do
    all = recent_questions(game, 200)

    # Roots and their followups
    {roots, followups} = Enum.split_with(all, &is_nil(&1.parent_question_id))
    followups_by_parent = Enum.group_by(followups, & &1.parent_question_id)

    roots
    |> Enum.map(fn root ->
      children = Map.get(followups_by_parent, root.id, [])
      %{root: root, followups: children}
    end)
    |> Enum.reject(fn %{root: r} -> String.contains?(r.answer || "", "Thinking...") end)
    |> Enum.sort_by(& &1.root.inserted_at, {:desc, DateTime})
  end

  @doc """
  Returns all question threads across all games.
  """
  def all_question_threads do
    roots =
      Repo.all(
        from q in QuestionLog,
          where: is_nil(q.parent_question_id),
          where: q.answer != "Thinking...",
          order_by: [desc: q.inserted_at],
          limit: 200,
          preload: [:game]
      )

    root_ids = Enum.map(roots, & &1.id)

    followups_by_parent =
      Repo.all(
        from q in QuestionLog,
          where: q.parent_question_id in ^root_ids,
          order_by: [asc: q.inserted_at]
      )
      |> Enum.group_by(& &1.parent_question_id)

    Enum.map(roots, fn root ->
      %{root: root, followups: Map.get(followups_by_parent, root.id, [])}
    end)
  end

  # ── Chunking (RAG) ──

  def chunk_document(%Document{} = doc) do
    Repo.delete_all(from c in Chunk, where: c.document_id == ^doc.id)

    pages = String.split(doc.full_text, "\f")

    chunks_with_meta =
      pages
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {page_text, page_num} ->
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

    # Insert all chunks with metadata
    Enum.each(chunks_with_meta, fn {text, idx, section, refs, pn} ->
      case %Chunk{}
           |> Chunk.changeset(%{
             document_id: doc.id,
             chunk_index: idx,
             content: text,
             section_label: section,
             references_section: refs,
             page_number: pn
           })
           |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          require Logger
          Logger.error("Failed to insert chunk #{idx}: #{inspect(changeset.errors)}")
      end
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

  def retrieve_chunks(%Game{} = game, question, limit \\ 6) do
    retrieve_chunks_for_games([game.id], question, limit)
  end

  def retrieve_chunks_for_games(game_ids, question, limit \\ 6) when is_list(game_ids) do
    # Try semantic retrieval via pgvector
    case RuleMaven.Embed.embed(question) do
      {:ok, question_vec} ->
        chunks =
          Repo.all(
            from c in Chunk,
              join: d in Document,
              on: c.document_id == d.id,
              where:
                d.game_id in ^game_ids and d.status == "published" and
                  not is_nil(c.embedding),
              order_by:
                fragment(
                  "cosine_distance(?, ?::vector)",
                  c.embedding,
                  ^Pgvector.new(question_vec)
                ),
              limit: ^limit,
              select: %{
                id: c.id,
                content: c.content,
                section_label: c.section_label,
                references_section: c.references_section
              }
          )

        if chunks == [] do
          # Fallback: full text from all games
          texts =
            Enum.map(game_ids, fn gid ->
              game = Repo.get!(Game, gid)
              document_full_text(game)
            end)
            |> Enum.reject(&(&1 == ""))

          Enum.map(texts, &{nil, &1})
        else
          chunks
          |> pull_referenced_chunks(game_ids)
          |> Enum.map(&{nil, &1.content})
        end

      {:error, _} ->
        # Fallback to keyword overlap across all games
        keyword_retrieve_multi(game_ids, question, limit)
    end
  end

  defp keyword_retrieve_multi(game_ids, question, limit) do
    chunks =
      Repo.all(
        from c in Chunk,
          join: d in Document,
          on: c.document_id == d.id,
          where: d.game_id in ^game_ids and d.status == "published",
          select: %{
            id: c.id,
            content: c.content,
            section_label: c.section_label,
            references_section: c.references_section
          }
      )

    if chunks == [] do
      texts =
        Enum.map(game_ids, fn gid ->
          game = Repo.get!(Game, gid)
          document_full_text(game)
        end)
        |> Enum.reject(&(&1 == ""))

      Enum.map(texts, &{nil, &1})
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
        texts =
          Enum.map(game_ids, fn gid ->
            game = Repo.get!(Game, gid)
            document_full_text(game)
          end)
          |> Enum.reject(&(&1 == ""))

        Enum.map(texts, &{nil, &1})
      else
        top_chunks = Enum.map(scored, fn {_, c} -> c end)
        top_chunks |> pull_referenced_chunks(game_ids) |> Enum.map(&{nil, &1.content})
      end
    end
  end

  # ── Chunk helpers ──

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
            where:
              d.game_id in ^game_ids and d.status == "published" and
                c.section_label in ^referenced_labels,
            select: %{
              id: c.id,
              content: c.content,
              section_label: c.section_label,
              references_section: c.references_section
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
      embedding = case RuleMaven.Embed.embed(text) do
        {:ok, vec} -> Pgvector.new(vec)
        _ -> nil
      end

      %GameCategory{}
      |> GameCategory.changeset(%{game_id: game.id, name: name, description: desc, name_embedding: embedding})
      |> Repo.insert!()
    end)

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
        |> Enum.filter(fn {_, dist} -> dist <= 0.5 end)

      Enum.each(top2, fn {cat_id, _} ->
        %QuestionCategoryTag{}
        |> QuestionCategoryTag.changeset(%{question_log_id: question_log_id, game_category_id: cat_id})
        |> Repo.insert(on_conflict: :nothing)
      end)

      :ok
    end
  end

  def retag_all_questions(%Game{} = game) do
    ids = Repo.all(
      from q in QuestionLog,
        where: q.game_id == ^game.id and q.refused == false and not is_nil(q.question_embedding),
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

    query = if community_only, do: from(q in query, where: q.visibility == "community"), else: query
    Repo.all(query)
  end

  def get_user_community_vote(question_log_id, user_id) do
    Repo.get_by(QuestionVote, question_log_id: question_log_id, user_id: user_id)
  end

  def set_community_vote(question_log_id, user_id, value) do
    existing = get_user_community_vote(question_log_id, user_id)

    cond do
      existing && existing.value == value ->
        Repo.delete(existing)
        nil

      existing ->
        existing
        |> QuestionVote.changeset(%{value: value})
        |> Repo.update!()
        value

      true ->
        %QuestionVote{}
        |> QuestionVote.changeset(%{question_log_id: question_log_id, user_id: user_id, value: value})
        |> Repo.insert!()
        value
    end
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
end
