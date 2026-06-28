defmodule RuleMaven.Repo.Migrations.AddEmailConfirmation do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_confirmed_at, :utc_datetime
    end

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])
  end
end
