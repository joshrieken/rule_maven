defmodule RuleMaven.ManualImport.Corrections do
  @moduledoc """
  Review loop for answers players say are wrong. An operator outside the app
  (Claude in a dev session, via `mix rule_maven.corrections` or the admin API)
  pulls the queue, checks each answer against the rulebook, and either
  corrects it or upholds it.

  Queue (`queue/1`): answers with unresolved report flags, plus thumbs-down
  answers not yet reviewed. "Reviewed" is recorded in the audit log
  (`answer.manual_correction` / `answer.review_upheld`), so an answer leaves
  the queue once handled and re-enters only through a new flag.

  `correct/3` holds a correction to the same bar as an imported answer: every
  citation must verify against the chunks of the row's game plus its
  expansion set (`Answers.ground_citations/3`). The fixed row is published to
  the pool, so the next matching ask gets the corrected ruling.
  """

  import Ecto.Query

  alias RuleMaven.{Audit, Coverage, Games, Repo}
  alias RuleMaven.Audit.AuditLog
  alias RuleMaven.Games.{QuestionFlag, QuestionLog}
  alias RuleMaven.ManualImport.Answers

  @verdicts ~w(legal illegal silent info)
  @reviewed_actions ~w(answer.manual_correction answer.review_upheld)

  @doc """
  Answers awaiting review, most-flagged first. Opts: `:game_id`, `:limit`
  (default 100). Each entry: `%{question: row, flag_count:, reasons:,
  thumbs_down: bool}`.
  """
  def queue(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    flags =
      Repo.all(
        from f in QuestionFlag,
          where: f.resolved == false,
          group_by: f.question_log_id,
          select:
            {f.question_log_id,
             {count(f.id), fragment("array_remove(array_agg(DISTINCT ?), NULL)", f.reason)}}
      )
      |> Map.new()

    reviewed =
      from a in AuditLog,
        where: a.target_type == "question" and a.action in ^@reviewed_actions,
        select: a.target_id

    down_ids =
      Repo.all(
        from q in QuestionLog,
          where: q.feedback == "down" and q.id not in subquery(reviewed),
          select: q.id
      )

    ids = Enum.uniq(Map.keys(flags) ++ down_ids)

    QuestionLog
    |> where([q], q.id in ^ids and is_nil(q.retracted_at))
    |> maybe_game(opts[:game_id])
    |> Repo.all()
    |> Enum.map(fn q ->
      {count, reasons} = Map.get(flags, q.id, {0, []})
      %{question: q, flag_count: count, reasons: reasons, thumbs_down: q.feedback == "down"}
    end)
    |> Enum.sort_by(&{-&1.flag_count, -&1.question.id})
    |> Enum.take(limit)
  end

  defp maybe_game(query, nil), do: query
  defp maybe_game(query, game_id), do: where(query, [q], q.game_id == ^game_id)

  @doc "Plain map of a queue entry for JSON output; `id_fun` encodes row/game ids."
  def entry_payload(%{question: q} = e, game_names, id_fun) do
    %{
      question: id_fun.(q.id),
      game: id_fun.(q.game_id),
      game_name: game_names[q.game_id],
      expansions: Enum.map(q.expansion_ids || [], id_fun),
      text: q.cleaned_question || q.question,
      answer: q.answer,
      verdict: q.verdict,
      citations: q.citations,
      flag_count: e.flag_count,
      reasons: e.reasons,
      thumbs_down: e.thumbs_down
    }
  end

  @doc "Game id => name for the games in a queue."
  def game_names(entries) do
    ids = entries |> Enum.map(& &1.question.game_id) |> Enum.uniq()

    Repo.all(from g in RuleMaven.Games.Game, where: g.id in ^ids, select: {g.id, g.name})
    |> Map.new()
  end

  @doc """
  Replaces a wrong answer: `%{"answer", "verdict", "citations" => [%{"quote",
  "page"}]}`. Returns `{:ok, row}` or `{:error, reason}` (nothing written).
  """
  def correct(%QuestionLog{} = row, %{"answer" => answer} = fix, actor) when is_binary(answer) do
    game = Games.get_game!(row.game_id)

    with :ok <- check_verdict(fix["verdict"]),
         {:ok, [first | _] = cites} <-
           Answers.ground_citations(game, row.expansion_ids || [], fix["citations"]),
         {:ok, row} <-
           Games.log_question_update(row, %{
             answer: answer,
             verdict: fix["verdict"],
             refused: fix["verdict"] == "silent",
             citations: cites,
             citation_valid: true,
             cited_passage: first["quote"],
             cited_page: first["page"],
             cited_source: first["source"],
             document_id: first["document_id"],
             llm_provider: "manual",
             llm_model: "claude-code"
           }),
         {:ok, row} <- Games.force_publish_question(row) do
      Coverage.record_citations(row)
      Games.resolve_flags(row.id)
      audit(actor, "answer.manual_correction", row, %{"note" => fix["note"]})
      {:ok, row}
    end
  end

  def correct(_row, _fix, _actor), do: {:error, :shape}

  @doc "Marks a reported answer as correct after review. Returns `{:ok, row}`."
  def uphold(%QuestionLog{} = row, note, actor) do
    Games.resolve_flags(row.id)
    audit(actor, "answer.review_upheld", row, %{"note" => note})
    {:ok, row}
  end

  @doc """
  Applies a batch of reviews: `[%{"question" => row_id, "action" =>
  "correct" | "uphold", …}]`, ids already resolved by the caller. Returns a
  list of `{row_id, :ok | {:error, reason}}`.
  """
  def apply_all(entries, actor) do
    for entry <- entries do
      id = entry["question"]

      result =
        case {Repo.get(QuestionLog, id), entry["action"]} do
          {nil, _} -> {:error, :not_found}
          {row, "correct"} -> correct(row, entry, actor)
          {row, "uphold"} -> uphold(row, entry["note"], actor)
          _ -> {:error, :bad_action}
        end

      {id, if(match?({:ok, _}, result), do: :ok, else: result)}
    end
  end

  defp check_verdict(v) when v in @verdicts, do: :ok
  defp check_verdict(_), do: {:error, :bad_verdict}

  defp audit(actor, action, row, metadata) do
    Audit.log(actor, action,
      target_type: "question",
      target_id: row.id,
      target_label: row.question,
      metadata: Map.reject(metadata, fn {_k, v} -> is_nil(v) end)
    )
  end
end
