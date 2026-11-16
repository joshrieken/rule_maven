defmodule RuleMaven.Repo.Migrations.AddSeenVersionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Newest release ("0.1.5") whose What's new notes the user has opened; nil = never.
      # Drives the red dot on the header's version link (RuleMaven.Changelog).
      add :seen_version, :string
    end
  end
end
