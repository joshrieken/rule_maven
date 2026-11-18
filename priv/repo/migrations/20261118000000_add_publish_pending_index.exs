defmodule RuleMaven.Repo.Migrations.AddPublishPendingIndex do
  use Ecto.Migration

  # Games.publish_pending_count/0 (admin dashboard, every load) seq-scanned
  # questions_log. A partial index over exactly its predicate turns it into an
  # index-only count of the (few) stuck rows. Additive: the previous release
  # ignores it.
  def change do
    create index(:questions_log, [:id],
             name: :questions_log_publish_pending_index,
             where: "browsable = false AND citation_valid = true AND cleaned_question IS NOT NULL"
           )
  end
end
