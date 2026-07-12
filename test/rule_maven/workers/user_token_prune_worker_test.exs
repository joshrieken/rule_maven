defmodule RuleMaven.Workers.UserTokenPruneWorkerTest do
  use RuleMaven.DataCase, async: true
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query

  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Users.UserToken
  alias RuleMaven.Workers.UserTokenPruneWorker

  defp user_fixture do
    {:ok, user} =
      Users.create_user(%{
        username: "prune#{System.unique_integer([:positive])}",
        email: "prune#{System.unique_integer([:positive])}@test.com",
        password: "testpass1234"
      })

    user
  end

  defp token_fixture(user, age_days, context \\ "confirm") do
    {_encoded, token} = UserToken.build_email_token(user, context)
    token = Repo.insert!(token)

    inserted_at =
      DateTime.utc_now() |> DateTime.add(-age_days, :day) |> DateTime.truncate(:second)

    Repo.update_all(from(t in UserToken, where: t.id == ^token.id),
      set: [inserted_at: inserted_at]
    )

    token
  end

  test "deletes old unconsumed tokens, keeps fresh ones" do
    user = user_fixture()

    # Well past the 14-day cutoff (7-day max validity + 7-day margin): an
    # unconsumed confirm token that could never verify again.
    old = token_fixture(user, 30)
    # Fresh tokens across contexts must survive — a 1-day-old confirm token is
    # still live (7-day validity), and a brand-new magic link is mid-flight.
    fresh_confirm = token_fixture(user, 1)
    fresh_magic = token_fixture(user, 0, "magic_link")

    assert :ok = perform_job(UserTokenPruneWorker, %{})

    refute Repo.get(UserToken, old.id)
    assert Repo.get(UserToken, fresh_confirm.id)
    assert Repo.get(UserToken, fresh_magic.id)
  end

  test "is idempotent: a second run with nothing to delete still succeeds" do
    user = user_fixture()
    token_fixture(user, 30)

    assert :ok = perform_job(UserTokenPruneWorker, %{})
    assert :ok = perform_job(UserTokenPruneWorker, %{})

    refute Repo.exists?(from t in UserToken, where: t.inserted_at < ago(14, "day"))
  end
end
