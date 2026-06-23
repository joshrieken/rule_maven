defmodule RuleMaven.Games.QuestionLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "questions_log" do
    field :question, :string
    field :answer, :string
    field :cited_passage, :string
    field :pinned, :boolean, default: false
    field :llm_provider, :string
    field :llm_model, :string
    field :cited_page, :integer
    field :question_embedding, Pgvector.Ecto.Vector
    field :source_chunk_ids, {:array, :integer}
    field :feedback, :string
    field :cluster_id, :integer
    field :visibility, :string, default: "private"
    field :refused, :boolean, default: false
    field :cleaned_question, :string
    field :raw_response, :string
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :parent_question, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(question_log, attrs) do
    question_log
    |> cast(attrs, [
      :question,
      :answer,
      :cited_passage,
      :game_id,
      :pinned,
      :llm_provider,
      :llm_model,
      :user_id,
      :cited_page,
      :question_embedding,
      :source_chunk_ids,
      :feedback,
      :cluster_id,
      :document_id,
      :visibility,
      :parent_question_id,
      :refused,
      :cleaned_question,
      :raw_response
    ])
    |> validate_required([:question, :answer, :game_id])
  end
end
