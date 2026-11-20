defmodule RuleMaven.Repo.Migrations.InviteCodesCreatorNullify do
  @moduledoc """
  The old sign-up invite codes are no longer used (the table is dropped in a later release, once no
  running release reads it). Until then, deleting a user who once made a code mustn't fail on the
  foreign key: it now sets `created_by_id` to NULL. Works with the previous release too.
  """
  use Ecto.Migration

  def up do
    alter table(:invite_codes) do
      modify :created_by_id, references(:users, on_delete: :nilify_all),
        from: references(:users, on_delete: :nothing)
    end
  end

  def down do
    alter table(:invite_codes) do
      modify :created_by_id, references(:users, on_delete: :nothing),
        from: references(:users, on_delete: :nilify_all)
    end
  end
end
