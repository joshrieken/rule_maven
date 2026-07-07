defmodule RuleMaven.Repo.Migrations.AddCuratorIncentives do
  use Ecto.Migration

  def change do
    alter table(:question_votes) do
      add :settled_at, :utc_datetime
      add :settled_outcome, :string
    end

    alter table(:users) do
      add :curator_points, :integer, default: 0, null: false
      add :curator_seen_at, :utc_datetime
    end

    # Monthly bonus-quota query: user's correct settles in current month.
    create index(:question_votes, [:user_id, :settled_at],
             where: "settled_outcome = 'correct'",
             name: :question_votes_user_correct_settled_idx
           )
  end
end
