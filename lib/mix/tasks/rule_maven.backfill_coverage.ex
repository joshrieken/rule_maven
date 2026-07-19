defmodule Mix.Tasks.RuleMaven.BackfillCoverage do
  @moduledoc """
  One-shot backfill: seeds `document_page_coverages` from citations already
  present on existing `questions_log` rows.

  Walks every question_log with non-empty citations, resolves each
  citation's `"source"` label to a published document id (scoped to the
  row's game plus its expansions), and records the covered pages via
  `RuleMaven.Coverage.record_citations/1`. Idempotent — `record_citations/1`
  upserts on `(document_id, page)` with `on_conflict: :nothing`, so re-runs
  add nothing new.

  Usage: `mix rule_maven.backfill_coverage`
  """
  use Mix.Task

  import Ecto.Query

  alias RuleMaven.{Coverage, Repo}
  alias RuleMaven.Games.QuestionLog

  @shortdoc "Seed document_page_coverages from existing question citations"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    # `citations` is a native Postgres array-of-map column (`{:array, :map}`
    # in Ecto), not a jsonb column — a `jsonb_array_length` WHERE fragment
    # would raise at runtime against this column type. Filter non-empty
    # citations in Elixir instead of relying on a DB-side jsonb predicate.
    from(q in QuestionLog,
      select: %{id: q.id, game_id: q.game_id, user_id: q.user_id, citations: q.citations}
    )
    |> Repo.all()
    |> Enum.reject(&(&1.citations in [nil, []]))
    |> Enum.each(fn ql ->
      game_ids = [ql.game_id | expansion_game_ids(ql.game_id)]
      stamped = Coverage.resolve_document_ids(ql.citations, game_ids)
      Coverage.record_citations(%{ql | citations: stamped})
    end)

    :ok
  end

  defp expansion_game_ids(game_id) do
    case RuleMaven.Games.get_game(game_id) do
      nil -> []
      game -> game |> RuleMaven.Games.expansions_for() |> Enum.map(& &1.id)
    end
  end
end
