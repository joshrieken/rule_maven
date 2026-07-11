defmodule RuleMaven.Repo.Migrations.ClosePregateOrphanRows do
  use Ecto.Migration

  @moduledoc """
  Closes the pre-gate ORPHAN rows: questions written by a crew that was later
  DELETED, during the window when no publish gate existed.

  Those rows have `group_id = NULL` (the FK is `on_delete: :nilify_all`), text
  that nothing ever screened, and — courtesy of `AddPublishGates`' `default: true`
  — `browsable = true`. `QuestionLog.listed_question/1` matches exactly that shape
  (`browsable: true, group_id: nil`) and falls through to the RAW question column,
  so they are listed verbatim on the public Unverified tab.

  This is a NEW migration rather than another edit to `20260711130000`. That file
  says, in its own docstring, that it exists precisely because `schema_migrations`
  keys on the version and an in-place edit "would never run anywhere it actually
  matters" — and then rounds 7 and 8 edited it in place twice. Any box that had
  already applied it would never see the correction, and the gate would look closed
  in tests (fresh DB) while standing open on the running one. So: forward-only.

  The statement is idempotent (it only ever closes rows that are still open), so a
  database that DID pick up the corrected version inside 20260711130000 simply
  matches nothing here.
  """

  # The exposure window: rows written after crews began existing (CreateGroups) and
  # before `browsable` existed to gate them (AddPublishGates).
  @create_groups 20_260_710_000_001
  @add_publish_gates 20_260_711_100_000

  def up do
    # Resolved in Elixir, not as a scalar subquery in the UPDATE. A missing version
    # row makes a subquery return NULL, which makes the whole WHERE NULL, which
    # updates ZERO rows — silently. A fail-closed gate that fails open on missing
    # data is worse than no gate, because it looks like one. If the window can't be
    # established, say so and stop.
    from = migrated_at(@create_groups)
    to = migrated_at(@add_publish_gates)

    cond do
      is_nil(from) ->
        # CreateGroups never ran here, so no crew ever wrote a row on this database
        # and there is nothing to close.
        :ok

      is_nil(to) ->
        raise """
        Cannot establish the pre-gate window: schema_migrations has \
        #{@create_groups} (CreateGroups) but not #{@add_publish_gates} \
        (AddPublishGates). Refusing to guess — a wrong window here either leaves \
        unscreened crew questions publicly listed or closes rows that were never \
        crew rows.
        """

      true ->
        repo().query!(
          """
          UPDATE questions_log
             SET browsable = false
           WHERE group_id IS NULL
             AND browsable = true
             AND visibility <> 'community'
             AND inserted_at >= $1
             AND inserted_at < $2
          """,
          [from, to]
        )
    end
  end

  # Deliberately irreversible: we cannot tell, after the fact, which of these rows
  # were crew rows and which were ordinary ones we over-closed. Re-opening them all
  # would re-publish the unscreened ones.
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
