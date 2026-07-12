defmodule RuleMaven.Repo.Migrations.WidenProviderFreetextToText do
  use Ecto.Migration

  # Two columns stored provider/LLM free-text in varchar(255) with no length
  # guard, so an over-long value crashed the write instead of being stored:
  #
  #   * llm_logs.error_message — a provider error body (e.g. a 401 JSON from the
  #     embedding API) can exceed 255 chars. The overflow crashed the AskWorker
  #     *at the logging step*, turning a surfaceable error into a silent hung ask.
  #   * questions_log.cited_source — copied verbatim from the LLM citation JSON;
  #     a model that puts a quote/sentence in "source" overflows it.
  #
  # text has no length cap, so the value stores intact.
  def up do
    alter table(:llm_logs) do
      modify :error_message, :text
    end

    alter table(:questions_log) do
      modify :cited_source, :text
    end
  end

  def down do
    alter table(:llm_logs) do
      modify :error_message, :string
    end

    alter table(:questions_log) do
      modify :cited_source, :string
    end
  end
end
