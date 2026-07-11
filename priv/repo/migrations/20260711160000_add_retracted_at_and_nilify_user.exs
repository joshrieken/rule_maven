defmodule RuleMaven.Repo.Migrations.AddRetractedAtAndNilifyUser do
  use Ecto.Migration

  @moduledoc """
  Two fixes from critique round 6.

  1. `retracted_at` — a DURABLE marker that a crew explicitly withdrew this row.

     Withdrawal was inferred, never recorded. `AskWorker` guessed at it with
     `is_nil(group_id) and not browsable`, which only fires once the group is
     gone (group_id is nilified on delete) — so a row retracted by a crew that
     still EXISTS was invisible to it. Flip `contribute_to_community` off and
     back on and every previously-withdrawn row was fair game to re-pool and
     re-publish, against a UI that calls the withdrawal permanent.

     Worse, `never_pool` is read once at the top of a job that then runs for up
     to 180 seconds. A retraction landing inside that window was simply undone:
     `mark_pooled/1` re-set `pooled: true` and the publish check — which never
     consulted the group's consent flag at all, only `pooled` — flipped
     `browsable: true` on a question the crew had just withdrawn.

     A column, unlike an inference, survives both the nilify and the race.

  2. `questions_log.user_id` → ON DELETE SET NULL.

     It was `on_delete: :nothing`, and `Users.do_delete_user/1` never clears the
     user's rows — so `Repo.delete(user)` raised a foreign-key violation for any
     user who had ever asked a question, rolling back the whole transaction
     INCLUDING `Groups.handle_owner_account_deletion/1`. A crew owner could not
     be deleted at all. The test suite missed it because every user it deletes
     is question-less.

     Nilifying is the right disposal here rather than cascading: a pooled answer
     already serves the commons anonymously, and the read paths tolerate a nil
     author (`recent_questions/3` renders `row.user && row.user.username`).
     Deleting the account anonymizes its questions; it does not retract them.
  """

  def up do
    alter table(:questions_log) do
      add :retracted_at, :utc_datetime_usec
    end

    # Rows the pre-round-6 `retract_contributions/1` already closed carry no
    # marker (it only wrote pooled/browsable). Reconstruct what we can: a group
    # row that is closed on both axes was either retracted or is simply awaiting
    # its publish check. The latter is `pooled: true` (AskWorker pools first,
    # then enqueues the check), so `pooled: false AND browsable: false` on a
    # group row is a retraction. Marking a not-yet-checked row as retracted would
    # only withhold it, never expose it, so this errs closed either way.
    execute(
      """
      UPDATE questions_log
         SET retracted_at = NOW()
       WHERE group_id IS NOT NULL
         AND pooled = false
         AND browsable = false
         AND visibility <> 'community'
      """,
      ""
    )

    drop constraint(:questions_log, "questions_log_user_id_fkey")

    alter table(:questions_log) do
      modify :user_id, references(:users, on_delete: :nilify_all)
    end
  end

  def down do
    drop constraint(:questions_log, "questions_log_user_id_fkey")

    alter table(:questions_log) do
      modify :user_id, references(:users, on_delete: :nothing)
      remove :retracted_at
    end
  end
end
