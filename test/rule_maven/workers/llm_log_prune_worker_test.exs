defmodule RuleMaven.Workers.LlmLogPruneWorkerTest do
  use RuleMaven.DataCase, async: true
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query

  alias RuleMaven.LLM.Log
  alias RuleMaven.Repo
  alias RuleMaven.Workers.LlmLogPruneWorker

  defp log_fixture(age_days) do
    log =
      Repo.insert!(%Log{
        provider: "openrouter",
        model: "test-model",
        operation: "ask",
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150,
        duration_ms: 1234,
        success: true,
        detail: %{"input" => "raw question preview", "output" => "answer preview"}
      })

    inserted_at =
      DateTime.utc_now() |> DateTime.add(-age_days, :day) |> DateTime.truncate(:second)

    Repo.update_all(from(l in Log, where: l.id == ^log.id), set: [inserted_at: inserted_at])
    log
  end

  test "strips detail from old rows, leaves recent rows and cost columns intact" do
    old = log_fixture(45)
    recent = log_fixture(5)

    assert :ok = perform_job(LlmLogPruneWorker, %{})

    old = Repo.get!(Log, old.id)
    recent = Repo.get!(Log, recent.id)

    # The old row survives (cost reporting needs it) but its bulky detail is gone.
    assert old.detail == nil
    assert old.prompt_tokens == 100
    assert old.completion_tokens == 50
    assert old.total_tokens == 150
    assert old.duration_ms == 1234
    assert old.model == "test-model"

    # The recent row keeps its trace detail for the admin panel.
    assert recent.detail == %{"input" => "raw question preview", "output" => "answer preview"}
  end

  test "is idempotent: a second run with nothing to strip still succeeds" do
    log_fixture(45)

    assert :ok = perform_job(LlmLogPruneWorker, %{})
    assert :ok = perform_job(LlmLogPruneWorker, %{})

    refute Repo.exists?(
             from l in Log,
               where: not is_nil(l.detail) and l.inserted_at < ago(30, "day")
           )
  end
end
