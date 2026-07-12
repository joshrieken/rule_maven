defmodule RuleMaven.Uploads do
  @moduledoc """
  Resolves where user-uploaded files (rulebook PDFs, extracted HTML) live on
  disk.

  The database only ever stores release-relative paths such as
  `"uploads/rulebooks/123_catan.pdf"`. Historically those were resolved under
  `Application.app_dir(:rule_maven, "priv/static")` — i.e. *inside* the
  release directory — which means every redeploy replaces the release dir and
  orphans all uploaded files.

  Setting the `UPLOADS_DIR` env var (wired in `config/runtime.exs` as the
  `:uploads_dir` app env) relocates the root to a path outside the release —
  typically a mounted volume — so uploads survive redeploys. The `nil`
  default preserves the historical in-release behavior byte-for-byte, so no
  data migration of stored paths is needed either way.
  """

  @doc "The absolute root directory under which relative upload paths resolve."
  def root do
    Application.get_env(:rule_maven, :uploads_dir) ||
      Application.app_dir(:rule_maven, "priv/static")
  end

  @doc "Resolves a DB-stored release-relative path (e.g. `\"uploads/rulebooks/x.pdf\"`) to an absolute path."
  def resolve(rel_path), do: Path.join(root(), rel_path)
end
