defmodule RuleMaven.Repo.Migrations.BackfillPublishApproval do
  use Ecto.Migration

  import Ecto.Query

  # A manual publish gate now controls the `playable` flag: a game only goes
  # playable once an admin approves it (readiness_publish_<id> = "on"). Games
  # that are already live predate the gate, so grandfather them in — otherwise
  # the next recompute would silently unpublish them.
  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      repo().all(from(g in "games", where: g.playable == true, select: g.id))
      |> Enum.map(fn id ->
        %{key: "readiness_publish_#{id}", value: "on", inserted_at: now, updated_at: now}
      end)

    if rows != [] do
      repo().insert_all("app_settings", rows, on_conflict: :nothing, conflict_target: :key)
    end
  end

  def down do
    repo().query!("DELETE FROM app_settings WHERE key LIKE 'readiness_publish_%'")
  end
end
