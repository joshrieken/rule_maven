defmodule RuleMaven.Workers.HouseRuleCheckWorker do
  @moduledoc """
  Durable RAW check for one house rule. Retrieves rulebook chunks, asks the LLM
  to classify the rule (matches/fills_gap/overrides/unclear), persists the
  result, and broadcasts `{:house_rule_checked, id}` on `game:<id>` — on
  failure too, so the LiveView clears its pending state.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:house_rule_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, HouseRules, Jobs, LLM}

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: oban_id,
        args: %{"house_rule_id" => id, "game_id" => game_id},
        attempt: attempt,
        max_attempts: max
      }) do
    hr = HouseRules.get(id)

    cond do
      is_nil(hr) ->
        :ok

      not RuleMaven.Flags.enabled?(:asks) ->
        kill_switch_failure(hr, game_id, oban_id)

      true ->
        run_check(hr, game_id, oban_id, attempt >= max)
    end
  end

  defp kill_switch_failure(hr, game_id, oban_id) do
    label =
      case Games.get_game(game_id) do
        %{name: name} -> "House rule check — #{name}"
        _ -> "House rule check"
      end

    run = Jobs.start_run("house_rule_check", {"house_rule", hr.id}, label, oban_job_id: oban_id)
    finalize_failure(hr, game_id, "LLM calls are disabled.")
    Jobs.finish_run(run, "skipped", "LLM calls disabled.")
    :ok
  end

  defp run_check(hr, game_id, oban_id, last_attempt?) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("house_rule_check", {"house_rule", hr.id}, "House rule check — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Checking house rule against the rulebook…")

    case LLM.check_house_rule(hr, game) do
      {:ok, results} ->
        case HouseRules.mark_checked(hr, put_body_embedding(results, hr, run)) do
          {:ok, _} ->
            broadcast(game_id, hr.id)
            Jobs.finish_run(run, "done", "Verdict: #{results.verdict}.")
            :ok

          {:error, _cs} ->
            Jobs.finish_run(run, "failed", "Couldn't save check results.")
            finalize_failure(hr, game_id, "Couldn't save check results.")
        end

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))

        if last_attempt? do
          finalize_failure(hr, game_id, "Check failed — you can re-check later.")
        else
          {:error, reason}
        end
    end
  end

  # Body embedding powers the answer-overlay match (HouseRules.overlay_rules).
  # Computed alongside every check so it always reflects the checked body; an
  # embed failure degrades to "no overlay for this rule", never fails the check.
  defp put_body_embedding(results, hr, run) do
    case RuleMaven.Embed.embed(hr.body) do
      {:ok, vec} ->
        Map.put(results, :body_embedding, vec)

      {:error, reason} ->
        Jobs.event(run, :warn, "Body embedding failed: #{inspect(reason)}")
        results
    end
  end

  defp finalize_failure(hr, game_id, note) do
    {:ok, _} = HouseRules.mark_failed(hr, note)
    broadcast(game_id, hr.id)
    :ok
  end

  defp broadcast(game_id, hr_id) do
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, "game:#{game_id}", {:house_rule_checked, hr_id})
  end
end
