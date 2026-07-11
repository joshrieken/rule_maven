defmodule RuleMaven.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :name, :string, null: false
      add :owner_id, references(:users, on_delete: :nilify_all), null: false
      add :invite_code, :string, null: false
      add :invite_active, :boolean, null: false, default: true
      add :member_cap, :integer, null: false, default: 12
      timestamps()
    end

    create unique_index(:groups, [:invite_code])
    create index(:groups, [:owner_id])

    create table(:group_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      timestamps()
    end

    create unique_index(:group_memberships, [:user_id, :group_id])
    create index(:group_memberships, [:group_id])
    create unique_index(:group_memberships, [:group_id],
      where: "role = 'owner'", name: :group_memberships_one_owner_index)

    alter table(:questions_log) do
      add :group_id, references(:groups, on_delete: :nilify_all)
    end

    create index(:questions_log, [:group_id], where: "group_id IS NOT NULL")
  end
end
