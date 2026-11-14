defmodule RuleMaven.ManualImport.Answers do
  @moduledoc """
  Imports hand-authored answers (e.g. to a game's suggested questions) as
  ordinary Q&A rows, held to the same bar the ask pipeline enforces:

    * every citation must pass `Citations.valid_citations/2` against the game's
      own chunks — one ungrounded quote rejects the answer (the ask pipeline
      would silently drop it; an import should be fixed instead);
    * the question is embedded so the answer pool can match it;
    * the row is then published through `Games.force_publish_question/1`
      (browsable + pooled, since citations are valid), tagged with categories
      and recorded for page coverage — what AskWorker + PublishCheckWorker do.

  Input: a list of
      %{"question", "answer", "verdict" (legal|illegal|silent|info),
        "citations" => [%{"quote", "page"}]}

  Already-answered questions (same text, same game, same expansion set) are
  skipped, so a re-run only adds what's missing.

  `expansion_ids:` imports the answers for the base game played WITH those
  (linked) expansions: citations may quote any of their rulebooks, and the
  rows carry the expansion set, so an ask with exactly those expansions
  toggled on is served from the pool.
  """

  import Ecto.Query

  alias RuleMaven.{Coverage, Embed, Games, Repo}
  alias RuleMaven.Games.{Chunk, Citations, Document, Game, QuestionLog}

  @verdicts ~w(legal illegal silent info)
  @provider "manual"
  @model "claude-code"

  @doc """
  Import answers for `game` as `user`. Returns
  `{:ok, %{imported:, skipped:, errors:}}`, or `{:error, :not_an_expansion}`
  when `expansion_ids` names a game that isn't one of `game`'s expansions.
  """
  def import(%Game{} = game, user, entries, opts \\ []) when is_list(entries) do
    expansion_ids = opts |> Keyword.get(:expansion_ids, []) |> Enum.uniq() |> Enum.sort()
    linked = MapSet.new(Games.expansions_for(game), & &1.id)

    if Enum.all?(expansion_ids, &MapSet.member?(linked, &1)),
      do: {:ok, import_all(game, user, entries, [game.id | expansion_ids])},
      else: {:error, :not_an_expansion}
  end

  defp import_all(game, user, entries, [_ | expansion_ids] = game_ids) do
    ctx = %{chunks: source_chunks(game_ids), game_ids: game_ids, expansion_ids: expansion_ids}

    Enum.reduce(entries, %{imported: 0, skipped: 0, errors: []}, fn entry, acc ->
      case import_one(game, user, entry, ctx) do
        {:ok, _} -> %{acc | imported: acc.imported + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        {:error, reason} -> %{acc | errors: acc.errors ++ [{entry["question"], reason}]}
      end
    end)
  end

  defp import_one(game, user, %{"question" => q, "answer" => a} = entry, ctx)
       when is_binary(q) and is_binary(a) do
    cond do
      entry["verdict"] not in @verdicts ->
        {:error, :bad_verdict}

      answered?(game, q, ctx.expansion_ids) ->
        :skipped

      true ->
        with {:ok, citations} <- validate_citations(entry["citations"], ctx),
             {:ok, vec} <- Embed.embed(q),
             {:ok, row} <- insert(game, user, entry, citations, vec, ctx.expansion_ids),
             {:ok, row} <- Games.force_publish_question(row) do
          Games.tag_question(row.id, game.id)
          Coverage.record_citations(row)
          {:ok, row}
        end
    end
  end

  defp import_one(_game, _user, _entry, _ctx), do: {:error, :shape}

  defp answered?(game, q, expansion_ids) do
    Repo.exists?(
      from r in QuestionLog,
        where:
          r.game_id == ^game.id and r.expansion_ids == ^expansion_ids and
            (r.question == ^q or r.cleaned_question == ^q)
    )
  end

  # Every citation must be grounded. `source` is the document label, which is
  # also what the chunk maps carry, so valid? scopes each quote to its book. A
  # citation without one is attributed to the book that contains the quote.
  defp validate_citations([_ | _] = cites, %{chunks: chunks, game_ids: game_ids}) do
    labels = chunks |> Enum.map(& &1.label) |> Enum.uniq()

    normalized =
      Enum.map(cites, fn c ->
        c = %{"quote" => c["quote"], "page" => c["page"], "source" => c["source"]}
        if c["source"], do: c, else: Map.put(c, "source", quoting_label(c, labels, chunks))
      end)

    valid = Citations.valid_citations(normalized, chunks)

    if length(valid) == length(normalized) do
      {:ok, Coverage.resolve_document_ids(valid, game_ids)}
    else
      {:error, {:ungrounded, Enum.map(normalized -- valid, & &1["quote"])}}
    end
  end

  defp validate_citations(_cites, _ctx), do: {:error, :no_citations}

  defp quoting_label(cite, labels, chunks) do
    Enum.find(labels, List.first(labels), fn label ->
      Citations.valid_citations([Map.put(cite, "source", label)], chunks) != []
    end)
  end

  defp insert(game, user, entry, [first | _] = citations, vec, expansion_ids) do
    Games.log_question(%{
      game_id: game.id,
      user_id: user && user.id,
      question: entry["question"],
      cleaned_question: entry["question"],
      question_normalized: true,
      answer: entry["answer"],
      verdict: entry["verdict"],
      refused: entry["verdict"] == "silent",
      citations: citations,
      citation_valid: true,
      cited_passage: first["quote"],
      cited_page: first["page"],
      cited_source: first["source"],
      document_id: first["document_id"],
      question_embedding: Pgvector.new(vec),
      expansion_ids: expansion_ids,
      llm_provider: @provider,
      llm_model: @model,
      browsable: true
    })
  end

  defp source_chunks(game_ids) do
    Repo.all(
      from c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where: d.game_id in ^game_ids,
        order_by: [d.id, c.chunk_index],
        select: %{label: d.label, content: c.content}
    )
  end
end
