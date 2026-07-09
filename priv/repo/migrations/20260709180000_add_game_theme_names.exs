defmodule RuleMaven.Repo.Migrations.AddGameThemeNames do
  use Ecto.Migration

  # Player-facing names for a game's two generated theme variants, e.g.
  # %{"light" => "Harbor Daylight", "dark" => "Longest Night"}. Generated
  # alongside the palette by ThemePaletteWorker. Nil for games whose palette
  # predates this column — the picker falls back to "Game Light"/"Game Dark".
  def change do
    alter table(:games) do
      add :theme_names, :map
    end
  end
end
