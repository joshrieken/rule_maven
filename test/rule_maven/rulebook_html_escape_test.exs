defmodule RuleMaven.RulebookHtmlEscapeTest do
  use ExUnit.Case, async: true

  test "PDF text is escaped in the rulebook's HTML copy" do
    dir = "test-rulebook-#{System.unique_integer([:positive])}"
    pdf = Path.join(dir, "book.pdf")
    File.mkdir_p!(RuleMaven.Uploads.resolve(dir))
    on_exit(fn -> File.rm_rf!(RuleMaven.Uploads.resolve(dir)) end)

    text = "\f===== SHEET 1 PAGE 1 =====\nRoll <script>alert(1)</script> & move\nsecond line"
    html_path = RuleMaven.RulebookDownloader.text_to_html(text, pdf)
    html = File.read!(RuleMaven.Uploads.resolve(html_path))

    assert html =~ "Roll &lt;script&gt;alert(1)&lt;/script&gt; &amp; move<br>second line"
    refute html =~ "<script>alert(1)"
  end
end
