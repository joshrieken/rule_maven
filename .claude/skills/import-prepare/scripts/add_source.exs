# Add a source document (FAQ / errata / reference) to a game that ALREADY has
# pooled answers, without the paid PoolRebuildWorker re-asking everything.
#   mix run --no-start .claude/skills/import-prepare/scripts/add_source.exs GAME_ID tmp/rebuild/out/<slug>_<kind>.json
#
# 1. disables pool rebuild for the import window (global setting, restored after)
# 2. imports the pages (create_document → chunk/embed + invalidate_pool)
# 3. cancels any PoolRebuildWorker job scheduled for this game
# 4. re-pools the Claude-imported answers (llm_provider "manual") that
#    invalidate_pool demoted — their citations still match the unchanged docs.
# AFTER: review existing answers against the new source (it may outrank them) and
# fix contradictions with `mix rule_maven.corrections` — see SKILL.md.
Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()
import Ecto.Query
alias RuleMaven.{Games, ManualImport, Repo, Settings}
alias RuleMaven.Games.QuestionLog

[gid, file] = System.argv()
game = Games.get_game!(String.to_integer(gid))
attrs = file |> File.read!() |> Jason.decode!()
prev = Settings.get("pool_rebuild_enabled")
Settings.put("pool_rebuild_enabled", "false")

try do
  {:ok, doc} = ManualImport.import(game, attrs)
  IO.puts("IMPORTED doc #{doc.id} \"#{doc.label}\" (#{doc.kind}, #{length(doc.pages)} pages, status #{doc.status})")

  # pending_review (short / low-prose text) is invisible to retrieval: approve now,
  # before the cancel + re-pool below (approval invalidates the pool again).
  if doc.status != "published" do
    {:ok, _} = Games.approve_document(doc)
    IO.puts("APPROVED doc #{doc.id} (was #{doc.status})")
  end

  {n, _} =
    Repo.update_all(
      from(j in Oban.Job,
        where: j.worker == "RuleMaven.Workers.PoolRebuildWorker" and
                 j.state in ["scheduled", "available", "retryable"] and
                 fragment("(?->>'game_id')::int = ?", j.args, ^game.id)
      ),
      set: [state: "cancelled", cancelled_at: DateTime.utc_now()]
    )

  IO.puts("CANCELLED pool rebuild jobs: #{n}")

  rows =
    Repo.all(
      from(q in QuestionLog,
        where: (q.game_id == ^game.id or fragment("? @> ARRAY[?]::integer[]", q.expansion_ids, ^game.id)) and
                 q.llm_provider == "manual" and q.citation_valid and not q.refused and is_nil(q.retracted_at)
      )
    )

  repooled =
    Enum.count(rows, fn q ->
      {:ok, q} = q |> QuestionLog.changeset(%{stale: false}) |> Repo.update()
      match?({:ok, _}, Games.force_publish_question(q))
    end)

  IO.puts("REPOOLED #{repooled}/#{length(rows)} imported answers")
after
  Settings.put("pool_rebuild_enabled", prev || "")
  IO.puts("pool_rebuild_enabled restored to #{inspect(prev)}")
end
