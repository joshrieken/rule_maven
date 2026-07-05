defmodule RuleMaven.Repo.Migrations.AddPopularityRankToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      add :popularity_rank, :integer
    end
  end
end
