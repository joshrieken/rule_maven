defmodule RuleMaven.AudienceModelTest do
  @moduledoc """
  The access/promotion model: the DB-generated `audience`/`tier` columns, the
  Elixir mirror in QuestionLog, and Games.reachable_by?/2 which reads them.
  """
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures
  import Ecto.Query

  alias RuleMaven.{Games, Groups, Repo}
  alias RuleMaven.Games.QuestionLog

  setup do
    game = game_fixture()
    %{game: game, owner: user!("aud_owner"), stranger: user!("aud_stranger")}
  end

  defp user!(prefix) do
    n = System.unique_integer([:positive])

    Repo.insert!(%RuleMaven.Users.User{
      username: "#{prefix}_#{n}",
      email: "#{prefix}_#{n}@test.com",
      password_hash: "x"
    })
  end

  defp row!(game, owner, attrs) do
    base = %{game_id: game.id, user_id: owner.id, question: "q", answer: "a"}

    %QuestionLog{}
    |> QuestionLog.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "generated audience/tier columns" do
    test "map every access-field combination to the right audience + tier", ctx do
      cases = [
        {%{}, "private", nil},
        {%{group_id: nil, browsable: true, pooled: true}, "public", "unverified"},
        {%{promoted: true}, "public", "community"},
        {%{promoted: true, verified: true}, "public", "admin"},
        # pooled without a passed screen is NOT public
        {%{pooled: true, browsable: false}, "private", nil}
      ]

      for {attrs, audience, tier} <- cases do
        row = row!(ctx.game, ctx.owner, attrs)
        assert row.audience == audience, "attrs #{inspect(attrs)} → audience #{row.audience}"
        assert row.tier == tier, "attrs #{inspect(attrs)} → tier #{inspect(row.tier)}"
      end
    end

    test "the stored column always equals the Elixir mirror (drift guard)", ctx do
      for attrs <- [
            %{},
            %{browsable: true, pooled: true},
            %{promoted: true},
            %{promoted: true, verified: true}
          ] do
        row = row!(ctx.game, ctx.owner, attrs)
        assert row.audience == to_string(QuestionLog.audience(row))
        assert (row.tier && String.to_atom(row.tier)) == QuestionLog.tier(row)
      end
    end

    test "recomputes on update_all, which bypasses the changeset", ctx do
      row = row!(ctx.game, ctx.owner, %{})
      assert row.audience == "private"

      {1, _} =
        Repo.update_all(from(q in QuestionLog, where: q.id == ^row.id),
          set: [promoted: true]
        )

      reloaded = Repo.reload!(row)
      assert reloaded.audience == "public"
      assert reloaded.tier == "community"
    end
  end

  describe "reachable_by?/2 truth table" do
    test "private row: owner only", ctx do
      q = row!(ctx.game, ctx.owner, %{})
      assert Games.reachable_by?(q, ctx.owner.id)
      refute Games.reachable_by?(q, ctx.stranger.id)
    end

    test "public row (screened): everyone", ctx do
      q = row!(ctx.game, ctx.owner, %{browsable: true, pooled: true})
      assert Games.reachable_by?(q, ctx.owner.id)
      assert Games.reachable_by?(q, ctx.stranger.id)
    end

    test "public row (community): everyone", ctx do
      q = row!(ctx.game, ctx.owner, %{promoted: true})
      assert Games.reachable_by?(q, ctx.stranger.id)
    end

    test "crew row: owner and members yes, stranger no", ctx do
      group = RuleMaven.GroupsFixtures.group_fixture(ctx.owner)
      mate = user!("aud_mate")
      {:ok, _} = Groups.join_by_code(mate, group.invite_code)

      q = row!(ctx.game, ctx.owner, %{group_id: group.id})
      assert q.audience == "crew"
      assert Games.reachable_by?(q, ctx.owner.id)
      assert Games.reachable_by?(q, mate.id)
      refute Games.reachable_by?(q, ctx.stranger.id)
    end
  end
end
