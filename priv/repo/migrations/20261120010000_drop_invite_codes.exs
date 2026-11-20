defmodule RuleMaven.Repo.Migrations.DropInviteCodes do
  @moduledoc """
  Drops the old sign-up invite codes, unused since v0.6.5 (people get in through the zone's sign-in:
  hub invites, access requests, or an Authentik admin). v0.6.6, the release running beside this one
  during the deploy, no longer reads or writes it. Group invite codes (`groups.invite_code`) stay.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:invite_codes)
  end

  def down do
    create table(:invite_codes) do
      add :code, :string, null: false
      add :max_uses, :integer, default: 1, null: false
      add :use_count, :integer, default: 0, null: false
      add :active, :boolean, default: true, null: false
      add :expires_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:created_by_id])
  end
end
