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

    # Closing `browsable` is not enough on its own. Every browse surface lists a
    # row on `visibility == "community"` ALONE (community_questions/2,
    # faq_questions/2, Faq.community_count/1) — and between CreateGroups and
    # AddPublishGates there was no gate at all, so DirectPromotionWorker could
    # already have promoted a crew row whose text nothing ever screened. Those
    # rows would stay publicly listed with `browsable: false` underneath them.
    # Send them back to private; they can earn their way out through the gate.
    execute("""
    UPDATE questions_log
       SET visibility = 'private', pooled = false
     WHERE group_id IS NOT NULL
       AND visibility = 'community'
    """)
  end

  def down do
    execute("UPDATE questions_log SET browsable = true WHERE group_id IS NOT NULL")
  end
end
