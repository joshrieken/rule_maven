defmodule RuleMaven.Repo.Migrations.AddHouseRuleOverlays do
  use Ecto.Migration

  def change do
    alter table(:house_rules) do
      add :body_embedding, :vector, size: 768
    end

    create table(:house_rule_deltas) do
      add :house_rule_id, references(:house_rules, on_delete: :delete_all), null: false
      add :question_hash, :string, null: false
      add :rule_body_hash, :string, null: false
      add :delta, :text

      timestamps()
    end

    create unique_index(:house_rule_deltas, [:house_rule_id, :question_hash, :rule_body_hash])
  end
end
