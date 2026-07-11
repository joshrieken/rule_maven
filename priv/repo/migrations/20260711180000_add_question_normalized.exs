defmodule RuleMaven.Repo.Migrations.AddQuestionNormalized do
  use Ecto.Migration

  @moduledoc """
  Records whether the NORMALIZE step actually rewrote this question — as a fact,
  not as an inference.

  Two separate gates (AskWorker's `unscrubbed_crew_row?/3`, PublishCheckWorker's
  last-ditch guard) needed to know "did the scrub run?", and both tried to
  reconstruct it by comparing `cleaned_question` to the raw `question`. That
  comparison never fires: the stored `cleaned_question` goes through
  `strip_game_name/2`, whose last act is

      if String.ends_with?(q, "?"), do: q, else: q <> "?"

  So on a normalize FALLBACK — any provider error, or a rewrite
  `accept_normalized?/2` rejects — the stored text is the raw question plus a
  question mark, which is never equal to the raw question. Both gates silently
  passed a row whose text nothing had scrubbed, and the crew's verbatim prose
  (and the answer written from it, which the ARGUMENT-SETTLING prompt rule fills
  with player names) went to the commons.

  `normalize_question/4` already distinguishes `{:ok, _}` from `{:fallback, _}`
  and simply threw the tag away. It is carried through to the row now.

  Defaults FALSE: a pre-existing row has no evidence its text was scrubbed, and
  the only thing this column gates is a crew row's publication. Unknown means
  withheld.
  """

  def change do
    alter table(:questions_log) do
      add :question_normalized, :boolean, default: false, null: false
    end
  end
end
