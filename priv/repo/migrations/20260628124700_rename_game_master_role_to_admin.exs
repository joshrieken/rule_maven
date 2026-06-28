defmodule RuleMaven.Repo.Migrations.RenameGameMasterRoleToAdmin do
  use Ecto.Migration

  # The "game_master" role was renamed to "admin"; migrate any existing rows.
  def up do
    execute("UPDATE users SET role = 'admin' WHERE role = 'game_master'")
  end

  def down do
    execute("UPDATE users SET role = 'game_master' WHERE role = 'admin'")
  end
end
