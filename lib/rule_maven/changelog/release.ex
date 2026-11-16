defmodule RuleMaven.Changelog.Release do
  @moduledoc "One `## vX.Y.Z (date)` CHANGELOG.md entry: its version, date and bullets per audience."
  defstruct version: nil, date: nil, everyone: [], admins: []

  @type t :: %__MODULE__{
          version: String.t(),
          date: Date.t() | nil,
          everyone: [String.t()],
          admins: [String.t()]
        }
end
