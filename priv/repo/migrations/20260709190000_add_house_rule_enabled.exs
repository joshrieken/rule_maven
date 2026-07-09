defmodule RuleMaven.Repo.Migrations.AddHouseRuleEnabled do
  use Ecto.Migration

  # `enabled` is a separate axis from `visibility` and `blocked`:
  #   visibility — who else can see this rule
  #   blocked    — an admin removed it from the community list
  #   enabled    — does it apply at MY table right now
  # A user turns a rule off for a session without losing it.
  def change do
    alter table(:house_rules) do
      add :enabled, :boolean, null: false, default: true
    end

    # overlay_rules/3 filters on {user, game, enabled} before the vector scan.
    create index(:house_rules, [:user_id, :game_id, :enabled])
  end
end
