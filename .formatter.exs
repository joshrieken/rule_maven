# lib/lccz is synced from hub/platform/elixir/lccz (formatted there, 120 columns): never reformatted here.
[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs:
    ["*.{heex,ex,exs}", "config/**/*.exs", "test/**/*.{heex,ex,exs}"] ++
      (Path.wildcard("lib/**/*.{heex,ex,exs}") -- Path.wildcard("lib/lccz/**/*.{heex,ex,exs}"))
]
