defmodule RuleMaven.PdfCompressTest do
  # async: false — flips the :ghostscript app env.
  use ExUnit.Case, async: false

  alias RuleMaven.Games.Document
  alias RuleMaven.PdfCompress

  setup do
    previous = Application.get_env(:rule_maven, :ghostscript)
    on_exit(fn -> Application.put_env(:rule_maven, :ghostscript, previous || "gs") end)
    path = Path.join(System.tmp_dir!(), "pdfc-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4 not really")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "no Ghostscript on PATH: skipped, file untouched", %{path: path} do
    Application.put_env(:rule_maven, :ghostscript, "definitely-not-ghostscript")
    assert {:skipped, {:missing, "definitely-not-ghostscript"}} = PdfCompress.compress_file(path)
    assert File.read!(path) == "%PDF-1.4 not really"
  end

  test "a missing file is skipped, not raised" do
    assert {:skipped, _} = PdfCompress.compress_file("/nonexistent/x.pdf")
  end

  test "documents without a PDF are skipped" do
    assert {:skipped, :no_pdf} = PdfCompress.compress_document(%Document{pdf_path: nil})
  end
end
