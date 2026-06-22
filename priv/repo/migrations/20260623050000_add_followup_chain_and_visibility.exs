defmodule RuleMaven.Repo.Migrations.AddFollowupChainAndVisibility do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :parent_question_id, references(:questions_log, on_delete: :nothing), null: true
      add :visibility, :string, default: "community", null: false
    end

    create index(:questions_log, [:parent_question_id])
    create index(:questions_log, [:game_id, :visibility])
  end
end
