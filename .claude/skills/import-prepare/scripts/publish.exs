# usage: mix run --no-start .claude/skills/import-prepare/scripts/publish.exs GAME_ID [USERNAME]
# Prints every readiness step, then approve_publish (marks the game Ready).
Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()
[id | rest] = System.argv()
username = List.first(rest) || "jrieken"
game = RuleMaven.Games.get_game!(String.to_integer(id))
admin = RuleMaven.Repo.get_by!(RuleMaven.Users.User, username: username)
for s <- RuleMaven.Readiness.state(game), do: IO.puts("STEP #{s.id} #{s.state}")
IO.puts("PLAYABLE #{inspect(RuleMaven.Readiness.approve_publish(game, admin))}")
