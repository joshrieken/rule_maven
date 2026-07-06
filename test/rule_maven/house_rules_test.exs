defmodule RuleMaven.HouseRulesTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.HouseRules
  alias RuleMaven.Users

  defp user_fixture do
    unique = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "hruser#{unique}",
        email: "hruser#{unique}@test.com",
        password: "testpass1234"
      })

    u
  end

  describe "create/3" do
    test "creates a pending private rule" do
      user = user_fixture()
      game = game_fixture()

      {:ok, hr} = HouseRules.create(user, game.id, %{"body" => "We deal 6 cards, not 5."})

      assert hr.visibility == "private"
      assert hr.check_status == "pending"
      assert hr.user_id == user.id
    end

    test "rejects body over 500 chars" do
      user = user_fixture()
      game = game_fixture()

      assert {:error, cs} =
               HouseRules.create(user, game.id, %{"body" => String.duplicate("x", 501)})

      assert %{body: _} = errors_on(cs)
    end
  end

  describe "visibility scoping" do
    test "community_for_game excludes private, blocked, and own rules" do
      owner = user_fixture()
      other = user_fixture()
      game = game_fixture()

      {:ok, _private} = HouseRules.create(other, game.id, %{"body" => "private one"})
      {:ok, shared} = HouseRules.create(other, game.id, %{"body" => "shared one"})
      {:ok, shared} = HouseRules.update(shared, %{"visibility" => "community"})
      {:ok, blocked} = HouseRules.create(other, game.id, %{"body" => "blocked one"})
      {:ok, blocked} = HouseRules.update(blocked, %{"visibility" => "community"})
      {:ok, _} = HouseRules.set_blocked(blocked, true)
      {:ok, _own} = HouseRules.create(owner, game.id, %{"body" => "mine"})

      ids = HouseRules.community_for_game(game.id, owner.id) |> Enum.map(& &1.id)
      assert ids == [shared.id]
    end
  end

  describe "check lifecycle" do
    test "mark_checked sets done + fields; mark_stale_for_game flips done to stale" do
      user = user_fixture()
      game = game_fixture()
      {:ok, hr} = HouseRules.create(user, game.id, %{"body" => "test rule"})

      {:ok, hr} =
        HouseRules.mark_checked(hr, %{
          verdict: "overrides",
          raw_quote: "Deal 5 cards to each player.",
          check_note: "Replaces the official hand size.",
          citations: [%{"quote" => "Deal 5 cards to each player.", "page" => 4}]
        })

      assert hr.check_status == "done"
      assert hr.checked_at

      assert 1 == HouseRules.mark_stale_for_game(game.id)
      assert HouseRules.get(hr.id).check_status == "stale"
    end
  end
end
