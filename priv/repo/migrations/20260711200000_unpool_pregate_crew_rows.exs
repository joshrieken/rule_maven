defmodule RuleMaven.Repo.Migrations.UnpoolPregateCrewRows do
  use Ecto.Migration

  @moduledoc """
  The two earlier backfills closed `browsable` and left `pooled` alone. That is
  the wrong half.

  Round 9's whole finding was that `pooled` — not `browsable` — is the column
  that actually carries a crew's answer out of the crew: `find_pool_candidates/3`
  selects on `q.pooled == true` with no `browsable` term at all, so a pooled row
  is served as a cache hit to any stranger asking a near-duplicate question in
  that game. `browsable` only governs whether the QUESTION TEXT gets listed.

  So a pre-gate crew row left at `pooled: true` is still feeding the commons an
  answer that nothing ever screened — the exact failure the gate was built to
  prevent, just arriving through the backfill instead of the queue-hop window.
  Nothing re-screens those rows either: `PublishCheckWorker` is only ever
  enqueued by `AskWorker` on a fresh answer.

  Forward-only, for the reason `20260711130000` states in its own docstring and
  then twice ignored: `schema_migrations` keys on the version, so editing an
  applied migration in place never runs anywhere it matters.
  """

  # The exposure window: rows written after crews began existing (CreateGroups)
  # and before `browsable` existed to gate them (AddPublishGates).
  @create_groups 20_260_710_000_001
  @add_publish_gates 20_260_711_100_000

  def up do
    # 1. Crew rows that still carry their group marker.
    #
    # `pooled AND NOT browsable` is an exact discriminator for "pre-gate", not a
    # heuristic: post-gate, the ONLY writer that sets `pooled: true` on a crew row
    # is `PublishCheckWorker.maybe_publish/3`, and it sets `pooled` and `browsable`
    # in the same statement. A crew row that is pooled but not browsable therefore
    # cannot have come through the gate — it predates it. Idempotent, and it leaves
    # every legitimately-screened crew row (pooled AND browsable) untouched.
    execute("""
    UPDATE questions_log
       SET pooled = false
     WHERE group_id IS NOT NULL
       AND pooled = true
       AND browsable = false
    """)

    # 2. Orphan rows: written by a crew that was DELETED, so the FK nilified
    # `group_id` and the marker is gone. There is no discriminator left, so we
    # close the whole window by timestamp — which also catches ordinary non-crew
    # rows written in it. That over-close is deliberate and cheap:
    #
    #   * On a fresh/production database every migration in this branch is applied
    #     in one run, so CreateGroups and AddPublishGates land milliseconds apart
    #     and the window contains no rows at all.
    #   * On a dev/staging box that ran the crew feature before the gate existed,
    #     the window holds exactly the rows nobody screened. Closing a handful of
    #     ordinary rows there is the correct trade against serving unscreened crew
    #     answers to strangers forever.
    #
    # `20260711190000` excluded `visibility = 'community'` from its close. That
    # exclusion is the hole: a pre-gate crew row could be promoted to community by
    # `DirectPromotionWorker` (on full-weight crew votes, since `unreviewable?`
    # didn't exist yet) and then be orphaned by a crew deletion — landing at
    # `browsable: true, group_id: nil, visibility: "community"`, which is the one
    # shape `listed_question/1` renders VERBATIM. Community rows are demoted to
    # private here for the same reason `20260711130000` demotes the non-orphan
    # ones; they can earn their way back out through the gate.
    from = migrated_at(@create_groups)
    to = migrated_at(@add_publish_gates)

    cond do
      is_nil(from) ->
        # CreateGroups never ran here, so no crew ever wrote a row on this
        # database and there is nothing to close.
        :ok

      is_nil(to) ->
        raise """
        Cannot establish the pre-gate window: schema_migrations has \
        #{@create_groups} (CreateGroups) but not #{@add_publish_gates} \
        (AddPublishGates). Refusing to guess — a wrong window here either leaves \
        unscreened crew answers pooled into the community cache or closes rows \
        that were never crew rows.
        """

      true ->
        repo().query!(
          """
          UPDATE questions_log
             SET pooled = false,
                 browsable = false,
                 visibility = CASE WHEN visibility = 'community' THEN 'private' ELSE visibility END
           WHERE group_id IS NULL
             AND (pooled = true OR browsable = true OR visibility = 'community')
             AND inserted_at >= $1
             AND inserted_at < $2
          """,
          [from, to]
        )
    end
  end

  # Deliberately irreversible: after the fact we cannot tell which of these rows
  # were crew rows and which were ordinary ones we over-closed. Re-pooling them
  # all would re-serve the unscreened ones.
  def down, do: :ok

  defp migrated_at(version) do
    case repo().query!(
           "SELECT inserted_at FROM schema_migrations WHERE version = $1",
           [version]
         ) do
      %{rows: [[at]]} -> at
      _ -> nil
    end
  end
end
