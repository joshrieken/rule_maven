defmodule RuleMaven.Repo.Migrations.AddSessionRevocationAndTakedowns do
  use Ecto.Migration

  def change do
    # Force-logout / session revocation: any session whose login timestamp
    # predates this cutoff is rejected. NULL = no sessions revoked.
    alter table(:users) do
      add :sessions_valid_after, :utc_datetime
    end

    # Lightweight DMCA takedown: hides the game everywhere and blocks new asks,
    # with a logged reason + complainant. Reversible (set back to NULL).
    alter table(:games) do
      add :taken_down_at, :utc_datetime
      add :takedown_reason, :text
      add :takedown_complainant, :string
    end

    create index(:games, [:taken_down_at])
  end
end
