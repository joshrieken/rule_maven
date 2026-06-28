defmodule RuleMaven.Repo.Migrations.RenamePinnedToVerified do
  use Ecto.Migration

  def change do
    rename table(:questions_log), :pinned, to: :verified
  end
end
