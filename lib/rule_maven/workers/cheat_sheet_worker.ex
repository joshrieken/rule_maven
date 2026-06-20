defmodule RuleMaven.Workers.CheatSheetWorker do
  @moduledoc """
  Oban job: generates cheatsheet content for a document, stores it
  on the document record. Uses existing CheatSheet module for LLM calls.
  """

  use Oban.Worker, queue: :cheatsheet, max_attempts: 2

  alias RuleMaven.Games

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => doc_id}}) do
    doc = Games.get_document!(doc_id)
    game = Games.get_game!(doc.game_id)

    case RuleMaven.CheatSheet.generate_content(game) do
      {:ok, content} ->
        Games.update_document(doc, %{
          cheatsheet: content,
          status: cheatsheet_ready_status(doc)
        })

        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cheatsheet_ready_status(doc) do
    # If document was pending review with a cheatsheet, it stays pending
    # Only auto-publish if clean extraction
    doc.status
  end
end
