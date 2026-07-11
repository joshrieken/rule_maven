defmodule Mix.Tasks.Qa.Wipe do
  @moduledoc """
  Deletes ALL questions & answers and everything hanging off them.

  `TRUNCATE questions_log RESTART IDENTITY CASCADE` clears questions_log plus its
  dependents (answer_voices, answer_favorites, question_votes, question_flags,
  question_category_tags). Games, rulebooks, documents, chunks and users are left
  untouched.

      mix qa.wipe         # prompts for confirmation
      mix qa.wipe --yes   # skip the prompt

  Destructive and irreversible — there is no undo.
  """
  use Mix.Task

  @shortdoc "Delete all questions, answers and adjacent rows"

  @children ~w(
    questions_log answer_voices answer_favorites
    question_votes question_flags question_category_tags
  )

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    repo = RuleMaven.Repo
    import Ecto.Query

    before = repo.aggregate("questions_log", :count)

    unless "--yes" in args do
      confirm =
        Mix.shell().prompt(
          "Delete #{before} question(s) and ALL adjacent rows? Type 'wipe' to confirm: "
        )
        |> to_string()
        |> String.trim()

      if confirm != "wipe" do
        Mix.shell().info("Aborted.")
        exit({:shutdown, 0})
      end
    end

    repo.query!("TRUNCATE questions_log RESTART IDENTITY CASCADE")

    for t <- @children do
      [%{c: c}] = repo.all(from r in t, select: %{c: count(r.id)})
      Mix.shell().info("#{t}=#{c}")
    end

    Mix.shell().info("Wiped (#{before} questions removed).")
  end
end
