defmodule RuleMaven.Repo.Migrations.DemotePregateCrewCommunityRows do
  use Ecto.Migration

  @moduledoc """
  `20260711200000` un-pooled the pre-gate crew rows and thought that closed them.
  It doesn't, for the ones that had already reached `visibility = 'community'`.

  `Games.find_pool_candidates/3` serves on:

      q.pooled == true or (q.visibility == "community" and q.citation_valid == true) or ...

  The community branch consults NEITHER `pooled` NOR `browsable`. So clearing
  `pooled` on a community row changes nothing — the answer keeps being served as
  a cross-user cache hit, and `PublishCheckWorker` never re-screens it (only
  AskWorker enqueues it, and only on a fresh answer). Statement 2 of 200000
  demotes `visibility` for the ORPHAN rows and gets this right; statement 1, for
  the rows that still carry their `group_id`, does not.

  How such a row exists: pre-gate, `DirectPromotionWorker` could promote a crew
  row on full-weight crew votes (`unreviewable?` didn't exist yet). The community
  demotion in `20260711130000` was added by an in-place EDIT, so a box that had
  already applied that version never ran it — which is the whole reason this
  branch's backfills are forward-only, and the reason this is a new file rather
  than a fix to 200000.

  Idempotent: it only ever closes rows that are still open.
  """

  def up do
    execute("""
    UPDATE questions_log
       SET visibility = 'private',
           pooled = false
     WHERE group_id IS NOT NULL
       AND browsable = false
       AND visibility = 'community'
    """)

    # A second, independent discriminator, because 200000's (`pooled AND NOT
    # browsable`) assumes the NEW code was already running when it landed.
    #
    # In a normal deploy — `mix ecto.migrate`, then boot the new release — the OLD
    # AskWorker keeps serving in between. It writes crew rows that take `browsable`'s
    # DB default of `true` and calls `mark_pooled/1` inline, so they land at
    # `pooled: true, browsable: true` and 200000 reads them as "legitimately
    # screened". They are not: nothing screened them.
    #
    # But the gate REQUIRES `question_normalized` before it will publish anything
    # (PublishCheckWorker.screen/2, and the update_all re-asserts it). So a crew row
    # that is pooled and browsable while recording no scrub cannot have come through
    # the gate, whatever its timestamps say. Close it and let it re-earn its way out.
    execute("""
    UPDATE questions_log
       SET pooled = false,
           browsable = false,
           visibility = CASE WHEN visibility = 'community' THEN 'private' ELSE visibility END
     WHERE group_id IS NOT NULL
       AND pooled = true
       AND browsable = true
       AND question_normalized = false
    """)
  end

  # Irreversible on purpose: re-promoting these would re-serve answers written
  # from questions nothing ever screened.
  def down, do: :ok
end
