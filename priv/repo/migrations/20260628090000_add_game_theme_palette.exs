defmodule RuleMaven.Repo.Migrations.AddGameThemePalette do
  use Ecto.Migration

  def change do
    alter table(:games) do
      # Per-game theme derived from the BGG cover. Shape:
      #   %{"light" => %{"--bg" => "#…", …}, "dark" => %{…}}
      # nil until the ThemePaletteWorker has run for the game.
      add :theme_palette, :map
    end
  end
end
