# usage (repo root): mix run --no-start .claude/skills/import-prepare/scripts/publish.exs GAME_ID [USERNAME]
# Prints every readiness step, approves publish, and explains a false result.
Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()
[id | rest] = System.argv()
username = List.first(rest) || "jrieken"
game = RuleMaven.Games.get_game!(String.to_integer(id))
admin = RuleMaven.Repo.get_by!(RuleMaven.Users.User, username: username)
steps = RuleMaven.Readiness.state(game)
for s <- steps, do: IO.puts("STEP #{s.id} #{s.state}")
playable = RuleMaven.Readiness.approve_publish(game, admin)
IO.puts("PLAYABLE #{inspect(playable)}")

if playable != true do
  pending = for s <- steps, to_string(s.state) != "done", do: s.id
  IO.puts("NOT READY — steps not done: #{inspect(pending)} (bgg is REQUIRED: run new_game.exs add BGG_ID; embed may still be running — wait and re-run)")
end
