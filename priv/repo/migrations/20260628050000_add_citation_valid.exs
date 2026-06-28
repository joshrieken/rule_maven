defmodule RuleMaven.Repo.Migrations.AddCitationValid do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # Whether the cited passage/page is actually grounded in the source chunks
      # the answer was generated from (vs. merely present). Gates auto-pooling
      # and the citation trust bonus.
      add :citation_valid, :boolean, default: false, null: false
    end
  end
end
