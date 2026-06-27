defmodule RuleMaven.Voices.AnswerVoice do
  @moduledoc """
  A cached in-character restyle of a canonical answer. Keyed by
  `(question_log_id, voice)` — generated once, shared with every viewer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "answer_voices" do
    field :voice, :string
    field :content, :string
    belongs_to :question_log, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end

  def changeset(av, attrs) do
    av
    |> cast(attrs, [:question_log_id, :voice, :content])
    |> validate_required([:question_log_id, :voice, :content])
    |> unique_constraint([:question_log_id, :voice])
  end
end
