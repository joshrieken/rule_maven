defmodule RuleMaven.Repo.Migrations.SeedSymbolFlags do
  use Ecto.Migration

  # Seeds the symbol-key flags at their registry default (on). Same reasoning
  # and mechanics as 20260711020000_seed_tool_flags: FunWithFlags treats a
  # missing row as OFF, and `mix ecto.migrate` has no OTP tree for its API.
  #   tool_symbols  — the Symbols table tool
  #   symbol_images — global kill switch for cropped rulebook icons (DMCA lever)
  @flags ~w(tool_symbols symbol_images)

  def up do
    flush()

    repo().insert_all(
      "fun_with_flags_toggles",
      Enum.map(
        @flags,
        &%{flag_name: &1, gate_type: "boolean", target: "_fwf_none", enabled: true}
      ),
      on_conflict: :nothing,
      conflict_target: [:flag_name, :gate_type, :target]
    )
  end

  def down do
    flush()

    repo().query!(
      "DELETE FROM fun_with_flags_toggles WHERE flag_name = ANY($1) AND gate_type = 'boolean'",
      [@flags]
    )
  end
end
