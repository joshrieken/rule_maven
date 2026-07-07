defmodule RuleMaven.Games.HouseRuleDelta do
  @moduledoc """
  Cached LLM "delta note" describing how one house rule changes one answer.
  Keyed by (house_rule, canonical-question hash, rule-body hash) so re-asks of
  the same canonical question reuse it and editing the rule body naturally
  misses the cache instead of serving a stale note.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "house_rule_deltas" do
    field :question_hash, :string
    field :rule_body_hash, :string
    field :delta, :string

    belongs_to :house_rule, RuleMaven.Games.HouseRule

    timestamps()
  end

  def changeset(hrd, attrs) do
    hrd
    |> cast(attrs, [:house_rule_id, :question_hash, :rule_body_hash, :delta])
    |> validate_required([:house_rule_id, :question_hash, :rule_body_hash, :delta])
    |> unique_constraint([:house_rule_id, :question_hash, :rule_body_hash])
  end
end
