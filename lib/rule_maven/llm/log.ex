defmodule RuleMaven.LLM.Log do
  use Ecto.Schema
  import Ecto.Changeset

  schema "llm_logs" do
    field :provider, :string
    field :model, :string
    field :operation, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer
    field :duration_ms, :integer
    field :success, :boolean, default: true
    field :error_message, :string
    # Plain id, not belongs_to: audit rows must survive question deletion
    # (regenerate/dedup delete question_logs rows).
    field :question_log_id, :integer
    # Per-call context for the admin trace panel: input/output previews,
    # finish_reason, cached prompt tokens, token cap, retry flags.
    field :detail, :map
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :user, RuleMaven.Users.User

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :provider,
      :model,
      :operation,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :duration_ms,
      :success,
      :error_message,
      :question_log_id,
      :detail,
      :game_id,
      :user_id
    ])
    |> validate_required([:provider, :model, :operation])
  end
end
