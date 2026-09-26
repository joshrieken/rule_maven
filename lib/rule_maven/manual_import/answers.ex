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

  Already-answered questions (same text, same game) are skipped, so a re-run
  only adds what's missing.
  """

  import Ecto.Query

  alias RuleMaven.{Coverage, Embed, Games, Repo}
  alias RuleMaven.Games.{Chunk, Citations, Document, Game, QuestionLog}

  @verdicts ~w(legal illegal silent info)
  @provider "manual"
  @model "claude-code"

  @doc "Import answers for `game` as `user`. Returns `{:ok, %{imported:, skipped:, errors:}}`."
  def import(%Game{} = game, user, entries) when is_list(entries) do
    chunks = source_chunks(game)

    Enum.reduce(entries, %{imported: 0, skipped: 0, errors: []}, fn entry, acc ->
      case import_one(game, user, entry, chunks) do
        {:ok, _} -> %{acc | imported: acc.imported + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        {:error, reason} -> %{acc | errors: acc.errors ++ [{entry["question"], reason}]}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp import_one(game, user, %{"question" => q, "answer" => a} = entry, chunks)
       when is_binary(q) and is_binary(a) do
    cond do
      entry["verdict"] not in @verdicts ->
        {:error, :bad_verdict}

      answered?(game, q) ->
        :skipped

      true ->
        with {:ok, citations} <- validate_citations(entry["citations"], chunks, game),
             {:ok, vec} <- Embed.embed(q),
             {:ok, row} <- insert(game, user, entry, citations, vec),
             {:ok, row} <- Games.force_publish_question(row) do
          Games.tag_question(row.id, game.id)
          Coverage.record_citations(row)
          {:ok, row}
        end
    end
  end

  defp import_one(_game, _user, _entry, _chunks), do: {:error, :shape}

  defp answered?(game, q) do
    Repo.exists?(
      from r in QuestionLog,
        where: r.game_id == ^game.id and (r.question == ^q or r.cleaned_question == ^q)
    )
  end

  # Every citation must be grounded. `source` is the document label, which is
  # also what the chunk maps carry, so valid? scopes each quote to its book.
  defp validate_citations([_ | _] = cites, chunks, game) do
    label = chunks |> List.first() |> Map.get(:label)

    normalized =
      Enum.map(cites, fn c ->
        %{"quote" => c["quote"], "page" => c["page"], "source" => c["source"] || label}
      end)

    valid = Citations.valid_citations(normalized, chunks)

    if length(valid) == length(normalized) do
      {:ok, Coverage.resolve_document_ids(valid, [game.id])}
    else
      {:error, {:ungrounded, Enum.map(normalized -- valid, & &1["quote"])}}
    end
  end

  defp validate_citations(_cites, _chunks, _game), do: {:error, :no_citations}

  defp insert(game, user, entry, [first | _] = citations, vec) do
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
      expansion_ids: [],
      llm_provider: @provider,
      llm_model: @model,
      browsable: true
    })
  end

  defp source_chunks(game) do
    Repo.all(
      from c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where: d.game_id == ^game.id,
        order_by: [d.id, c.chunk_index],
        select: %{label: d.label, content: c.content}
    )
  end
end
