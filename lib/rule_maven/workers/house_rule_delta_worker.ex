defmodule RuleMaven.Workers.HouseRuleDeltaWorker do
  @moduledoc """
  Durable delta note for one (house rule, answered question) pair: asks the LLM
  how the rule changes that answer, caches the note in house_rule_deltas, and
  broadcasts `{:house_rule_delta, house_rule_id, question_log_id, status}` on
  `game:<id>` — on failure too, so the LiveView clears its pending state.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:house_rule_id, :question_log_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, HouseRules, Jobs, LLM, Settings}

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: oban_id,
        args: %{"house_rule_id" => hr_id, "question_log_id" => ql_id},
        attempt: attempt,
        max_attempts: max
      }) do
    hr = HouseRules.get(hr_id)
    ql = Games.get_question_log(ql_id)

    cond do
      is_nil(hr) or is_nil(ql) ->
        :ok

      Settings.asks_disabled?() ->
        broadcast(hr.game_id, hr.id, ql.id, :failed)
        :ok

      # Answered again since the click, or someone raced us: cache already warm.
      HouseRules.get_delta(hr, ql) ->
        broadcast(hr.game_id, hr.id, ql.id, :done)
        :ok

      true ->
        run_delta(hr, ql, oban_id, attempt >= max)
    end
  end

  defp run_delta(hr, ql, oban_id, last_attempt?) do
    game = Games.get_game!(hr.game_id)

    run =
      Jobs.start_run(
        "house_rule_delta",
        {"house_rule", hr.id},
        "House rule delta — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Explaining how the house rule changes this answer…")

    case LLM.house_rule_delta(hr, ql, game) do
      {:ok, text} ->
        case HouseRules.save_delta(hr, ql, text) do
          {:ok, _} ->
            broadcast(game.id, hr.id, ql.id, :done)
            Jobs.finish_run(run, "done", "Delta note cached.")
            :ok

          {:error, _cs} ->
            Jobs.finish_run(run, "failed", "Couldn't save delta note.")
            broadcast(game.id, hr.id, ql.id, :failed)
            :ok
        end

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))

        if last_attempt? do
          broadcast(game.id, hr.id, ql.id, :failed)
          :ok
        else
          {:error, reason}
        end
    end
  end

  defp broadcast(game_id, hr_id, ql_id, status) do
    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      "game:#{game_id}",
      {:house_rule_delta, hr_id, ql_id, status}
    )
  end
end
