defmodule RuleMaven.UsersToursTest do
  @moduledoc "Onboarding tours-seen tracking on the user."

  use RuleMaven.DataCase, async: true

  alias RuleMaven.Users

  defp create_user do
    {:ok, user} =
      Users.create_user(%{
        username: "tour_user",
        email: "tour_user@test.com",
        password: "password1234"
      })

    user
  end

  test "tours start unseen and mark_tour_seen stamps them" do
    user = create_user()

    refute Users.tour_seen?(user, "games")
    refute Users.tour_seen?(user, "game")

    {:ok, user} = Users.mark_tour_seen(user, "games")
    assert Users.tour_seen?(user, "games")
    refute Users.tour_seen?(user, "game")

    # Stored as ISO8601 so it survives the jsonb round-trip.
    assert {:ok, _, _} = DateTime.from_iso8601(user.tours_seen["games"])

    {:ok, user} = Users.mark_tour_seen(user, "game")
    assert Users.tour_seen?(user, "game")
  end

  test "marking one tour keeps the other's timestamp" do
    user = create_user()
    {:ok, user} = Users.mark_tour_seen(user, "games")
    first = user.tours_seen["games"]

    {:ok, user} = Users.mark_tour_seen(user, "game")
    assert user.tours_seen["games"] == first
  end
end
