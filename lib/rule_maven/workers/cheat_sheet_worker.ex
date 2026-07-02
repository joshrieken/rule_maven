defmodule RuleMaven.Workers.CheatSheetWorker do
  @moduledoc """
  Oban job: pre-generates a cheat sheet for a freshly created document and
  persists it as a `CheatSheetVersion` (the first version is marked active).

  Previously wrote to a non-existent `doc.cheatsheet` field, so the LLM result
  was silently discarded — this stores it where the app actually reads it.

  Distinct from `CheatSheetGenWorker`: that one drives the game form's
  on-demand "Generate" button (writes the `cheat_*_<game_id>` Settings state
  machine the form polls, unique per game). This one fires automatically on
  document creation (`Games.create_document/1`) to pre-warm the first version,
  keyed per document.
  """

  use Oban.Worker, queue: :cheatsheet, max_attempts: 2

  alias RuleMaven.{Games, CheatSheet, Jobs}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"document_id" => doc_id}}) do
    doc = Games.get_document!(doc_id)
    game = Games.get_game!(doc.game_id)

    run =
      Jobs.start_run("cheat_sheet", {"document", doc_id}, "Cheat sheet — #{doc.label}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Generating cheat sheet…")

    case CheatSheet.generate_content(game) do
      {:ok, content} ->
        CheatSheet.save_version(doc_id, content)
        Jobs.finish_run(run, "done", "Generated (#{String.length(content)} chars).")
        {:ok, content}

      {:error, reason} ->
        Jobs.finish_run(run, "failed", to_string(reason))
        {:error, reason}
    end
  end
end
