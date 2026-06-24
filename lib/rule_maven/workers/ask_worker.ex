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

    if RuleMaven.Security.prompt_injection?(question) do
      if ql = get_question_log!(question_log_id) do
        Games.log_question_update(ql, %{
          answer: "⚠️ This question was blocked by the security filter.",
          refused: true,
          blocked: true
        })
        RuleMaven.PubSub.broadcast_ask_complete(game_id, question_log_id)
      end

      :ok
    else

    case RuleMaven.LLM.ask(game, question, expansion_ids, recent_context, user_id: user_id) do
      {:ok, %{answer: raw_answer} = llm_result} ->
        answer =
          cond do
            is_nil(raw_answer) || String.trim(raw_answer) == "" ->
              "⚠️ The AI returned an empty response. Please retry."

            true ->
              # Strip echo of original question from top of answer (exact or near-exact match)
              stripped = strip_question_echo(raw_answer, question)
              if String.trim(stripped) == "", do: raw_answer, else: stripped
          end

        if ql = get_question_log!(question_log_id) do
          raw_passage = llm_result[:cited_passage]
          followup? = llm_result[:followup] || false
          cited_page = parse_cited_page(raw_passage)
          # Strip [Page N] markers from display passage AFTER extracting page number
          passage =
            if raw_passage do
              raw_passage
              |> String.replace(~r/\[Page\s*\d+\]/i, "")
              |> String.replace(~r/\(Page\s*\d+\)/i, "")
              |> String.trim()
            end

          refused? = refused?(answer)

          cleaned =
            llm_result[:cleaned_question]
            |> to_string()
            |> String.trim()
            |> strip_game_name(game.name)

          update_attrs = %{
            answer: answer,
            question: if(cleaned != "", do: cleaned, else: question),
            cited_passage: passage,
            cited_page: cited_page,
            refused: refused?,
            cleaned_question: llm_result[:cleaned_question],
            raw_response: llm_result[:raw_response],
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

          case Games.log_question_update(ql, update_attrs) do
            {:ok, _updated} ->
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

            {:error, changeset} ->
              require Logger

              Logger.error(
                "AskWorker DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
              )

              Phoenix.PubSub.broadcast(
                RuleMaven.PubSub,
                "game:#{game_id}",
                {:ask_error,
                 %{
                   question_log_id: question_log_id,
                   question: question,
                   error: "Failed to save answer"
                 }}
              )
          end
        end

        :ok

      {:error, reason} ->
        require Logger
        Logger.error("AskWorker failed for game #{game_id}: #{reason}")

        friendly =
          cond do
            is_binary(reason) && String.contains?(reason, "timeout") ->
              "⚠️ The AI took too long to respond. Please retry."
            is_binary(reason) && String.contains?(reason, "rate") ->
              "⚠️ Too many requests — please wait a moment and retry."
            is_binary(reason) && String.contains?(reason, "context") ->
              "⚠️ Question too long for the AI to process. Try a shorter question."
            true ->
              "⚠️ Something went wrong. Please retry."
          end

        if ql = get_question_log!(question_log_id) do
          case Games.log_question_update(ql, %{answer: friendly}) do
            {:ok, _updated} ->
              Phoenix.PubSub.broadcast(
                RuleMaven.PubSub,
                "game:#{game_id}",
                {:ask_error,
                 %{question_log_id: question_log_id, question: question, error: reason}}
              )

            {:error, changeset} ->
              Logger.error(
                "AskWorker error DB update failed for question #{question_log_id}: #{inspect(changeset.errors)}"
              )
          end
        end

        :ok
    end
    end  # end prompt_injection? else
  end


  defp get_question_log(id) do
    import Ecto.Query
    alias RuleMaven.Games.QuestionLog

    RuleMaven.Repo.one(from q in QuestionLog, where: q.id == ^id)
  end

  defp get_question_log!(id) do
    case get_question_log(id) do
      nil ->
        require Logger
        Logger.warning("AskWorker: question_log #{id} not found, likely deleted by retry")
        nil

      q ->
        q
    end
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

  defp strip_game_name(question, game_name) when is_binary(question) and is_binary(game_name) do
    escaped = Regex.escape(game_name)
    # Strip " in Game Name" or " in Game Name?" suffix
    question
    |> String.replace(~r/ in #{escaped}\??$/i, "")
    |> String.replace(~r/ \(#{escaped}\)\??$/i, "")
    |> String.trim()
    |> then(fn q -> if String.ends_with?(q, "?"), do: q, else: q <> "?" end)
  end

  defp strip_game_name(question, _), do: question

  defp strip_question_echo(answer, question) do
    q = String.trim(question)

    case String.split(answer, "\n", parts: 2) do
      [first_line | rest] ->
        fl = String.trim(first_line)

        similar? =
          String.downcase(fl) == String.downcase(q) ||
            (String.ends_with?(fl, "?") &&
               String.jaro_distance(String.downcase(fl), String.downcase(q)) > 0.82)

        if similar?, do: String.trim(Enum.join(rest, "\n")), else: answer

      _ ->
        answer
    end
  end
end
