defmodule RuleMaven.RuleOfTheDayTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.{RuleOfTheDay, Settings}

  test "returns nil when no game has facts" do
    assert RuleOfTheDay.pick() == nil
  end

  test "picks deterministically per date from a Ready game's facts" do
    game = published_game_fixture(%{name: "Daily Game"})
    facts = ["Fact one.", "Fact two.", "Fact three."]
    Settings.put("did_you_know_#{game.id}", Jason.encode!(facts))

    date = ~D[2026-07-07]
    pick = RuleOfTheDay.pick(date)

    assert pick.game.id == game.id
    assert pick.fact in facts
    # Same date → same fact; the spotlight holds still all day.
    assert RuleOfTheDay.pick(date) == pick
  end

  test "skips non-Ready games and strips page markers" do
    hidden = game_fixture(%{name: "Not Ready", bgg_id: 77})
    Settings.put("did_you_know_#{hidden.id}", Jason.encode!(["Hidden fact."]))
    assert RuleOfTheDay.pick() == nil

    ready = published_game_fixture(%{name: "Ready Game", bgg_id: 78})
    Settings.put("did_you_know_#{ready.id}", Jason.encode!(["A rule. [Page 3]"]))

    pick = RuleOfTheDay.pick()
    assert pick.game.id == ready.id
    assert pick.fact == "A rule."
  end
end
