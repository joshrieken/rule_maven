defmodule RuleMaven.GamesExpansionSelectionTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Games, Repo}

  defp game(name) do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  defp user do
    Repo.insert!(%RuleMaven.Users.User{
      username: "sel_user_#{System.unique_integer([:positive])}",
      email: "sel#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  # A published-doc expansion linked to base.
  defp expansion_for(base) do
    exp = game("Exp")
    Games.link_expansion(exp.id, base.id)

    {:ok, doc} = Games.create_document(%{game_id: exp.id, label: "R", full_text: "rules text"})
    {:ok, _} = Games.update_document(doc, %{status: "published"})
    exp
  end

  test "put/get round-trips sorted; get is nil before any put" do
    u = user()
    base = game("Base")

    assert Games.get_expansion_selection(u.id, base.id) == nil

    :ok = Games.put_expansion_selection(u.id, base.id, [9, 4])
    assert Games.get_expansion_selection(u.id, base.id) == [4, 9]

    # Upsert replaces.
    :ok = Games.put_expansion_selection(u.id, base.id, [])
    assert Games.get_expansion_selection(u.id, base.id) == []
  end

  test "effective_expansion_ids: explicit selection wins, filtered to available" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)

    :ok = Games.put_expansion_selection(u.id, base.id, [exp.id, 999_999])
    assert Games.effective_expansion_ids(u.id, base) == [exp.id]
  end

  test "effective_expansion_ids: defaults from user's collection when never chosen" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)
    _unowned = expansion_for(base)

    Repo.insert!(%RuleMaven.Games.UserCollection{user_id: u.id, game_id: exp.id})

    assert Games.effective_expansion_ids(u.id, base) == [exp.id]
  end

  test "effective_expansion_ids: empty explicit choice beats collection default" do
    u = user()
    base = game("Base")
    exp = expansion_for(base)
    Repo.insert!(%RuleMaven.Games.UserCollection{user_id: u.id, game_id: exp.id})

    :ok = Games.put_expansion_selection(u.id, base.id, [])
    assert Games.effective_expansion_ids(u.id, base) == []
  end
end
