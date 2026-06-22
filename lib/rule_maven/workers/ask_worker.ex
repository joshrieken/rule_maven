defmodule RuleMaven.Workers.AskWorker do
  @moduledoc """
  Background LLM ask. Enqueue from LiveView to avoid blocking the process.
  Calls LLM.ask, updates the pre-logged question + answer, then broadcasts
  result via PubSub.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  alias RuleMaven.Games

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    game_id = args["game_id"]
    question_log_id = args["question_log_id"]
    question = args["question"]
    expansion_ids = args["expansion_ids"] || []

    recent_context =
      (args["recent_context"] || [])
      |> Enum.map(fn %{"q" => q, "a" => a} -> {q, a} end)

    game = Games.get_game!(game_id)

    case RuleMaven.LLM.ask(game, question, expansion_ids, recent_context) do
      {:ok, %{answer: answer} = llm_result} ->
        passage = llm_result[:cited_passage]

        Games.log_question_update(get_question_log!(question_log_id), %{
          answer: answer,
          cited_passage: passage,
          llm_provider: llm_result[:provider],
          llm_model: llm_result[:model],
          question_embedding: llm_result[:question_embedding]
        })

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:ask_complete,
           %{
             question_log_id: question_log_id,
             faq_hit: llm_result[:faq_hit] || false,
             followup: llm_result[:followup] || false,
             followups: llm_result[:followups] || []
           }}
        )

        :ok

      {:error, reason} ->
        require Logger
        Logger.error("AskWorker failed for game #{game_id}: #{reason}")

        Games.log_question_update(get_question_log!(question_log_id), %{
          answer: "⚠️ #{reason}"
        })

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:ask_error, %{question: question, error: reason}}
        )

        :ok
    end
  end

  defp get_question_log!(id) do
    import Ecto.Query
    alias RuleMaven.Games.QuestionLog

    RuleMaven.Repo.one!(from q in QuestionLog, where: q.id == ^id)
  end
end
