# Find or create a catalog game WITHOUT the in-app BGG worker (which would queue
# the paid ThemePaletteWorker). Run from the repo root:
#   mix run --no-start .claude/skills/import-prepare/scripts/new_game.exs search "Gloomhaven"
#   mix run --no-start .claude/skills/import-prepare/scripts/new_game.exs add BGG_ID ["Name"] [--expansion-of BASE_GAME_ID]
# `add` reuses an existing row with that bgg_id, fetches BGG data directly
# (weight, players, image, expansion links) and, for an expansion, links it.
Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()
alias RuleMaven.{BGG, Games, Repo}

case System.argv() do
  ["search", query] ->
    {:ok, hits} = BGG.search(query)

    for h <- hits do
      row = Repo.get_by(Games.Game, bgg_id: h.bgg_id)
      IO.puts("bgg #{h.bgg_id}  #{h.name} (#{h.year})  #{if row, do: "→ game #{row.id}", else: "not in catalog"}")
    end

  ["add", bgg | rest] ->
    {exp_of, rest} =
      case Enum.split_while(rest, &(&1 != "--expansion-of")) do
        {names, ["--expansion-of", base]} -> {String.to_integer(base), names}
        {names, []} -> {nil, names}
      end

    bgg_id = String.to_integer(bgg)

    game =
      Repo.get_by(Games.Game, bgg_id: bgg_id) ||
        (fn ->
           {:ok, g} = Games.create_game(%{name: List.first(rest) || "BGG #{bgg_id}", bgg_id: bgg_id})
           g
         end).()

    {:ok, game} = BGG.enrich_game(game, force: true)
    if exp_of, do: Games.link_expansion(game.id, exp_of)

    IO.puts(
      "GAME #{game.id} #{game.name} (#{game.year_published}) weight=#{inspect(game.weight)} " <>
        "expansion=#{Games.expansion?(game.id)} bgg_listed_expansions=#{BGG.expansion_link_count(game)}"
    )

  _ ->
    IO.puts("usage: search QUERY | add BGG_ID [NAME] [--expansion-of BASE_ID]")
end
