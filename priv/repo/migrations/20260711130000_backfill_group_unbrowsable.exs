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

    # Both statements above key on `group_id IS NOT NULL` — the exact inference
    # the rest of this codebase forbids, and for the exact reason: the column is
    # `on_delete: :nilify_all`. A crew DELETED during the pre-gate window (between
    # CreateGroups and AddPublishGates, when no gate existed at all) left rows with
    # a NULL group_id, never-screened text, and — courtesy of AddPublishGates'
    # `default: true` — `browsable: true`. `listed_question/1` matches
    # `%{browsable: true, group_id: nil}` and falls through to the RAW question
    # column. Those rows are listed, verbatim, on the public Unverified tab, and
    # the two statements above cannot see them. The backfill made the mistake it
    # was written to fix.
    #
    # Their provenance marker is gone for good, so this errs SHUT rather than open:
    # close every row that could plausibly be one — authored by someone who belongs
    # to a crew, written after crews existed, not already public. That over-closes
    # some ordinary personal rows of crew members. The cost of over-closing is that
    # a row stays off the Unverified tab (its owner still sees it, and its answer
    # still serves the pool); the cost of under-closing is publishing someone's
    # verbatim private question. Those are not comparable.
    # Every narrowing predicate has to survive the very deletion it is looking for.
    # `groups` and `group_memberships` do NOT: a deleted crew leaves no group row
    # and (memberships cascade) no membership rows, so keying on either matches
    # nothing in exactly the case this statement exists for — while still closing
    # ordinary rows of surviving crews' members. The worst of both.
    #
    # `schema_migrations` survives, and it dates the window precisely: the exposure
    # is rows written after CreateGroups (when crews began writing rows) and before
    # AddPublishGates (when `browsable` first existed). Outside that window a NULL
    # group_id genuinely means "never a crew row". Inside it, over-closing is cheap
    # — the row stays off the Unverified tab, its owner still sees it, its answer
    # still serves — and under-closing publishes someone's verbatim private
    # question. Those costs are not comparable, so this errs shut across the window.
    execute("""
    UPDATE questions_log
       SET browsable = false
     WHERE group_id IS NULL
       AND browsable = true
       AND visibility <> 'community'
       AND inserted_at >= (
         SELECT inserted_at FROM schema_migrations WHERE version = 20260710000001
       )
       AND inserted_at < (
         SELECT inserted_at FROM schema_migrations WHERE version = 20260711100000
       )
    """)
  end

  def down do
    execute("UPDATE questions_log SET browsable = true WHERE group_id IS NOT NULL")
  end
end
