defmodule RuleMaven.Repo.Migrations.AddToursSeenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Onboarding tours the user has completed/skipped: tour id ("games",
      # "game") => ISO8601 timestamp. Empty map = brand-new user, auto-start.
      add :tours_seen, :map, default: %{}, null: false
    end
  end
end
