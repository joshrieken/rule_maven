defmodule RuleMaven.Repo.Migrations.BackfillGroupUnbrowsable do
  use Ecto.Migration

  @moduledoc """
  Close the pre-gate crew rows.

  `AddPublishGates` added `browsable` with `default: true`, which is right for
  every pre-existing NON-group row (they were already listed) and wrong for the
  group rows written by the persistent-groups feature, which shipped BEFORE the
  gate existed — their text has never been screened.

  This lives in its own migration rather than in `AddPublishGates` because that
  version has already been applied on the dev/staging boxes: `schema_migrations`
  keys on the version, so an in-place edit there would never run anywhere it
  actually matters, and the gate would look closed in tests (fresh DB) while
  standing wide open on a running one.
  """

  def up do
    execute("UPDATE questions_log SET browsable = false WHERE group_id IS NOT NULL")
  end

  def down do
    execute("UPDATE questions_log SET browsable = true WHERE group_id IS NOT NULL")
  end
end
