defmodule RuleMaven.HouseRules do
  @moduledoc """
  House-rule variants users log per game. Each rule gets an async LLM check
  classifying it against rules-as-written (see Workers.HouseRuleCheckWorker).
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Games.HouseRule
  alias RuleMaven.{Games, Security, Workers}

  def get(id), do: Repo.get(HouseRule, id)

  def list_for_user(game_id, user_id) do
    Repo.all(
      from h in HouseRule,
        where: h.game_id == ^game_id and h.user_id == ^user_id,
        order_by: [desc: h.inserted_at]
    )
  end

  def community_for_game(game_id, exclude_user_id \\ nil) do
    base =
      from h in HouseRule,
        where:
          h.game_id == ^game_id and h.visibility == "community" and h.blocked == false,
        order_by: [desc: h.inserted_at]

    query =
      if exclude_user_id,
        do: from(h in base, where: h.user_id != ^exclude_user_id),
        else: base

    Repo.all(query)
  end

  def create(user, game_id, attrs) do
    %HouseRule{user_id: user.id, game_id: game_id}
    |> HouseRule.changeset(attrs)
    |> Repo.insert()
  end

  def update(%HouseRule{} = hr, attrs) do
    hr |> HouseRule.changeset(attrs) |> Repo.update()
  end

  def delete(%HouseRule{} = hr), do: Repo.delete(hr)

  def mark_checked(%HouseRule{} = hr, %{verdict: _} = results) do
    attrs =
      results
      |> Map.take([:verdict, :raw_quote, :check_note, :citations])
      |> Map.merge(%{
        check_status: "done",
        checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    hr |> HouseRule.check_changeset(attrs) |> Repo.update()
  end

  def mark_failed(%HouseRule{} = hr, note) do
    hr
    |> HouseRule.check_changeset(%{check_status: "failed", check_note: note})
    |> Repo.update()
  end

  def mark_pending(%HouseRule{} = hr) do
    hr |> HouseRule.check_changeset(%{check_status: "pending"}) |> Repo.update()
  end

  def mark_stale_for_game(game_id) do
    {count, _} =
      Repo.update_all(
        from(h in HouseRule, where: h.game_id == ^game_id and h.check_status == "done"),
        set: [check_status: "stale"]
      )

    count
  end

  def set_blocked(%HouseRule{} = hr, blocked?) do
    hr
    |> Ecto.Changeset.change(blocked: blocked?)
    |> Repo.update()
  end

  @doc """
  UI entry point: guard (injection, rate limit) → insert → enqueue check.
  """
  def submit(user, game_id, attrs) do
    body = to_string(attrs["body"] || attrs[:body] || "")

    with :ok <- injection_guard(body),
         :ok <- Games.check_rate_limit(user),
         {:ok, hr} <- create(user, game_id, attrs) do
      enqueue_check(hr)
      {:ok, hr}
    end
  end

  @doc "Edit; re-checks (and re-bills) only when the body changed."
  def update_and_recheck(user, %HouseRule{} = hr, attrs) do
    if hr.user_id == user.id do
      new_body = to_string(attrs["body"] || attrs[:body] || hr.body)

      if new_body != hr.body do
        with :ok <- injection_guard(new_body),
             :ok <- Games.check_rate_limit(user),
             {:ok, hr} <- __MODULE__.update(hr, attrs),
             {:ok, hr} <- mark_pending(hr) do
          enqueue_check(hr)
          {:ok, hr}
        end
      else
        __MODULE__.update(hr, attrs)
      end
    else
      {:error, :not_owner}
    end
  end

  @doc "Re-check button for failed/stale rules. Counts against quota."
  def resubmit_check(user, %HouseRule{} = hr) do
    if hr.user_id == user.id do
      with :ok <- Games.check_rate_limit(user),
           {:ok, hr} <- mark_pending(hr) do
        enqueue_check(hr)
        {:ok, hr}
      end
    else
      {:error, :not_owner}
    end
  end

  defp injection_guard(body) do
    if Security.prompt_injection?(body), do: {:error, :injection}, else: :ok
  end

  defp enqueue_check(hr) do
    %{"house_rule_id" => hr.id, "game_id" => hr.game_id}
    |> Workers.HouseRuleCheckWorker.new()
    |> Oban.insert()
  end
end
