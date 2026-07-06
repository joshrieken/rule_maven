defmodule RuleMaven.HouseRules do
  @moduledoc """
  House-rule variants users log per game. Each rule gets an async LLM check
  classifying it against rules-as-written (see Workers.HouseRuleCheckWorker).
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Games.HouseRule

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
end
