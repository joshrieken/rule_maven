defmodule Mix.Tasks.RuleMaven.VetGeneratedVoices do
  @shortdoc "Backfill the style vet for every game's unvetted generated persona voices"
  @moduledoc """
  Runs the persona style vet (`RuleMaven.LLM.vet_voice_styles/2`) over every
  game that still has `vetted: false` generated voices and marks the safe ones
  vetted, so those personas take the single-call streaming ask path instead of
  the slower two-phase restyle path on their next use.

  New voices are already vetted at creation time (`VoiceSuggestionsWorker`);
  this task exists to backfill voices generated before vetting existed (or whose
  vet call failed there), which otherwise only get vetted lazily on the first
  ask that happens to use them. One LLM call per game with unvetted voices.

  Real-person impersonations flagged by the vet are deleted (mirrors
  `VoiceVetWorker`), clearing their cached restyles.

      mix rule_maven.vet_generated_voices            # vet + mark safe
      mix rule_maven.vet_generated_voices --dry-run  # report only, no writes
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Repo, Voices}
  alias RuleMaven.Voices.GameVoice

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dry_run? = "--dry-run" in args

    game_ids =
      Repo.all(
        from gv in GameVoice,
          where: gv.vetted == false,
          distinct: true,
          select: gv.game_id
      )

    if game_ids == [] do
      Mix.shell().info("No unvetted generated voices — nothing to do.")
    else
      Mix.shell().info(
        "#{length(game_ids)} game(s) with unvetted voices#{if dry_run?, do: " (dry run)", else: ""}."
      )

      Enum.each(game_ids, &vet_game(&1, dry_run?))
    end
  end

  defp vet_game(game_id, dry_run?) do
    unvetted = Voices.unvetted_generated(game_id)

    case RuleMaven.LLM.vet_voice_styles(unvetted, game_id: game_id) do
      {:ok, %{safe: safe_slugs, real_person: real_person_slugs}} ->
        if dry_run? do
          Mix.shell().info(
            "game #{game_id}: WOULD mark #{length(safe_slugs)}/#{length(unvetted)} safe" <>
              real_person_note(" WOULD delete", real_person_slugs)
          )
        else
          Voices.mark_vetted(game_id, safe_slugs, unvetted)
          Voices.drop_generated(game_id, real_person_slugs)

          Mix.shell().info(
            "game #{game_id}: marked #{length(safe_slugs)}/#{length(unvetted)} safe" <>
              real_person_note(" deleted", real_person_slugs)
          )
        end

      {:error, reason} ->
        Mix.shell().error("game #{game_id}: vet failed (#{inspect(reason)}) — skipped.")
    end
  end

  defp real_person_note(_verb, []), do: "."

  defp real_person_note(verb, slugs),
    do: ";#{verb} #{length(slugs)} real-person persona(s): #{Enum.join(slugs, ", ")}."
end
