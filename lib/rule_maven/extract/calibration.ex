defmodule RuleMaven.Extract.Calibration do
  @moduledoc """
  One escalation outcome: the gate signals that triggered it and whether the
  strong re-read materially differed from the cheap candidate. The training data
  for learning which pages are safe to stop escalating.
  """
  use Ecto.Schema

  schema "extract_calibrations" do
    field :agreement, :float
    field :coverage, :float
    field :cheap_wordish, :float
    field :cheap_tokens, :integer
    field :strong_tokens, :integer
    field :jaccard_strong_cheap, :float
    field :materially_differed, :boolean
    field :drift_sample, :boolean, default: false

    timestamps(updated_at: false)
  end
end
