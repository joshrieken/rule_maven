defmodule RuleMaven.Repo.Migrations.DropContributeToCommunity do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      remove :contribute_to_community, :boolean, null: false, default: true
    end
  end
end
