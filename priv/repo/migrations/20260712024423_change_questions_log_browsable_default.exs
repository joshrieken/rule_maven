defmodule RuleMaven.Repo.Migrations.ChangeQuestionsLogBrowsableDefault do
  use Ecto.Migration

  def up do
    alter table(:questions_log) do
      modify :browsable, :boolean, default: false
    end
  end

  def down do
    alter table(:questions_log) do
      modify :browsable, :boolean, default: true
    end
  end
end
