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
    user_id = args["user_id"]

    recent_context =
      (args["recent_context"] || [])
      |> Enum.map(fn %{"q" => q, "a" => a} -> {q, a} end)

    game = Games.get_game!(game_id)

    case RuleMaven.LLM.ask(game, question, expansion_ids, recent_context, user_id: user_id) do
      {:ok, %{answer: answer} = llm_result} ->
        passage = llm_result[:cited_passage]
        followup? = llm_result[:followup] || false
        cited_page = parse_cited_page(passage)
        refused? = refused?(answer)

        update_attrs = %{
          answer: answer,
          cited_passage: passage,
          cited_page: cited_page,
          refused: refused?,
          cleaned_question: llm_result[:cleaned_question],
          llm_provider: llm_result[:provider],
          llm_model: llm_result[:model],
          question_embedding: llm_result[:question_embedding]
        }

        update_attrs =
          if followup? && user_id do
            parent_id = Games.find_parent_question_id(game_id, user_id, question_log_id)
            Map.put(update_attrs, :parent_question_id, parent_id)
          else
            update_attrs
          end

        Games.log_question_update(get_question_log!(question_log_id), update_attrs)

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:ask_complete,
           %{
             question_log_id: question_log_id,
             faq_hit: llm_result[:faq_hit] || false,
             followup: followup?,
             followups: if(refused?, do: [], else: llm_result[:followups] || []),
             cited_page: cited_page,
             refused: refused?,
             raw_response: llm_result[:raw_response]
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

  defp parse_cited_page(nil), do: nil

  defp parse_cited_page(passage) do
    case Regex.run(~r/\[Page\s+(\d+)\]/, passage) do
      [_, num] -> String.to_integer(num)
      nil -> nil
    end
  end

  @refusal_phrase "The rulebook does not cover this question."

  defp refused?(answer) do
    String.trim(answer) == @refusal_phrase
  end
end
