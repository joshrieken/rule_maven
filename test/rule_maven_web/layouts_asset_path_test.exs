defmodule RuleMavenWeb.LayoutsAssetPathTest do
  use ExUnit.Case, async: true

  alias RuleMavenWeb.Layouts

  # Test/dev boot without a digest manifest, so asset_path/1 must fall back to
  # the mtime query-string bust. (The manifest branch — digested URLs with
  # ?vsn=d — only exists in prod, where config/prod.exs sets
  # cache_static_manifest and `mix assets.deploy` has run phx.digest.)
  test "without a manifest, asset_path falls back to an mtime version bust" do
    assert Layouts.asset_path("assets/js/app.js") ==
             "/assets/js/app.js?v=" <> Layouts.asset_version("assets/js/app.js")

    refute Layouts.asset_version("assets/js/app.js") == "0"
  end

  test "asset_version is 0 for a missing file" do
    assert Layouts.asset_version("assets/js/definitely_missing.js") == "0"
  end
end
