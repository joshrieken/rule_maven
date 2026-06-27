defmodule RuleMaven.Repo.Migrations.CreateExtractCalibrations do
  use Ecto.Migration

  def change do
    create table(:extract_calibrations) do
      # Gate signals at the escalation decision (the features).
      add :agreement, :float
      add :coverage, :float
      add :cheap_wordish, :float
      add :cheap_tokens, :integer
      # Outcome: how much the strong re-read differed from the cheap candidate.
      add :strong_tokens, :integer
      add :jaccard_strong_cheap, :float
      add :materially_differed, :boolean
      # True when this row came from a drift sample (an agreed page escalated on
      # purpose to check the gate's "ceiling" assumption still holds).
      add :drift_sample, :boolean, default: false

      timestamps(updated_at: false)
    end

    create index(:extract_calibrations, [:inserted_at])
    create index(:extract_calibrations, [:materially_differed])
  end
end
