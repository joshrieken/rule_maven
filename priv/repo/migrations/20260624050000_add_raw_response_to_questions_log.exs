defmodule RuleMaven.Repo.Migrations.AddRawResponseToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :raw_response, :text, null: true
    end
  end
end
