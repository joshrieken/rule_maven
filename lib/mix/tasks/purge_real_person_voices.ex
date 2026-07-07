defmodule Mix.Tasks.RuleMaven.PurgeRealPersonVoices do
  @shortdoc "Re-vet ALL generated persona voices and delete real-person impersonations"
  @moduledoc """
  Runs the persona vet (`RuleMaven.LLM.vet_voice_styles/2`) over every game's
  generated voices — including ones already marked `vetted`, which predate the
  real-person check — and deletes any flagged as depicting a real person
  (e.g. Catan's "spirit of Klaus Teuber"), clearing their cached restyles.

  Only deletes on an explicit real-person verdict; a vet error for a game
  skips that game and is reported. The `vetted` flag is NOT touched here —
  this task only purges. Safe to re-run (idempotent once flagged voices are
  gone). One LLM call per game with generated voices.

      mix rule_maven.purge_real_person_voices            # delete flagged voices
      mix rule_maven.purge_real_person_voices --dry-run  # report only
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Repo, Voices}
  alias RuleMaven.Voices.GameVoice

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dry_run? = "--dry-run" in args

    game_ids = Repo.all(from gv in GameVoice, distinct: true, select: gv.game_id)

    if game_ids == [] do
      Mix.shell().info("No games have generated voices.")
    else
      Enum.each(game_ids, fn game_id ->
        voices = Voices.all_generated(game_id)

        case RuleMaven.LLM.vet_voice_styles(voices, game_id: game_id) do
          {:ok, %{real_person: []}} ->
            Mix.shell().info("game #{game_id}: #{length(voices)} voices, none flagged.")

          {:ok, %{real_person: slugs}} ->
            if dry_run? do
              Mix.shell().info(
                "game #{game_id}: WOULD delete #{Enum.join(slugs, ", ")} (dry run)."
              )
            else
              Voices.drop_generated(game_id, slugs)
              Mix.shell().info("game #{game_id}: deleted #{Enum.join(slugs, ", ")}.")
            end

          {:error, reason} ->
            Mix.shell().error("game #{game_id}: vet failed (#{inspect(reason)}) — skipped.")
        end
      end)
    end
  end
end
