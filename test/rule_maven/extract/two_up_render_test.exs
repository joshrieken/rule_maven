defmodule RuleMaven.Extract.TwoUpRenderTest do
  @moduledoc """
  Validates the external assumptions the 2-up pipeline makes about poppler:
  that `pdftoppm -x/-y/-W/-H` crop flags are pixels at the requested dpi and
  that `TwoUp.crop_args/4` therefore isolates exactly one half of a sheet.
  Uses an ImageMagick-built landscape PDF (black left half, white right half);
  skipped when the CLI tools aren't installed.
  """
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.TwoUp
  alias RuleMaven.RulebookDownloader

  @have_tools Enum.all?(~w(magick pdftoppm pdfinfo), &System.find_executable/1)
  @moduletag skip: not @have_tools

  # 400x200 pt landscape sheet: left half solid black, right half solid white.
  setup_all do
    if @have_tools do
      dir = Path.join(System.tmp_dir!(), "two_up_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      pdf = Path.join(dir, "spread.pdf")

      {_, 0} =
        System.cmd("magick", [
          "-size",
          "400x200",
          "canvas:white",
          "-fill",
          "black",
          "-draw",
          "rectangle 0,0,199,199",
          pdf
        ])

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir, pdf: pdf}
    else
      :ok
    end
  end

  defp render_half(pdf, dir, half, dpi) do
    prefix = Path.join(dir, "out_#{half}_#{dpi}")

    args =
      ["-jpeg", "-gray", "-r", to_string(dpi), "-f", "1", "-l", "1"] ++
        TwoUp.crop_args(400.0, 200.0, dpi, half) ++ [pdf, prefix]

    {_, 0} = System.cmd("pdftoppm", args)
    [img] = Path.wildcard(prefix <> "*")
    img
  end

  defp identify(img, format) do
    {out, 0} = System.cmd("magick", ["identify", "-format", format, img])
    out
  end

  test "crop args isolate exactly one half at the render dpi", %{pdf: pdf, dir: dir} do
    # 400 pts at 144 dpi → 800 px wide, 400 px tall; each half 400x400.
    left = render_half(pdf, dir, :left, 144)
    right = render_half(pdf, dir, :right, 144)

    assert identify(left, "%w %h") == "400 400"
    assert identify(right, "%w %h") == "400 400"

    # Left half of the fixture is black, right half white — the mean gray
    # level proves the crop grabbed the correct half, not a rescale of both.
    assert String.to_float(identify(left, "%[fx:mean]")) < 0.2
    assert String.to_float(identify(right, "%[fx:mean]")) > 0.8
  end

  test "two_up_suspect? flags a wide sheet and not a portrait one", %{pdf: pdf, dir: dir} do
    # two_up_suspect? takes static-relative paths; stage fixtures under the
    # app's priv/static.
    static = Application.app_dir(:rule_maven, "priv/static")
    rel_wide = "uploads/rulebooks/two_up_suspect_wide_test.pdf"
    rel_tall = "uploads/rulebooks/two_up_suspect_tall_test.pdf"
    File.mkdir_p!(Path.join(static, "uploads/rulebooks"))
    File.cp!(pdf, Path.join(static, rel_wide))

    tall = Path.join(dir, "tall.pdf")
    {_, 0} = System.cmd("magick", ["-size", "200x400", "canvas:white", tall])
    File.cp!(tall, Path.join(static, rel_tall))

    on_exit(fn ->
      File.rm(Path.join(static, rel_wide))
      File.rm(Path.join(static, rel_tall))
    end)

    assert RulebookDownloader.two_up_suspect?(rel_wide)
    refute RulebookDownloader.two_up_suspect?(rel_tall)
  end

  test "portrait_sheet? flags a tall sheet and not a wide one", %{pdf: pdf, dir: dir} do
    static = Application.app_dir(:rule_maven, "priv/static")
    rel_wide = "uploads/rulebooks/portrait_sheet_wide_test.pdf"
    rel_tall = "uploads/rulebooks/portrait_sheet_tall_test.pdf"
    File.mkdir_p!(Path.join(static, "uploads/rulebooks"))
    File.cp!(pdf, Path.join(static, rel_wide))

    tall = Path.join(dir, "portrait.pdf")
    {_, 0} = System.cmd("magick", ["-size", "200x400", "canvas:white", tall])
    File.cp!(tall, Path.join(static, rel_tall))

    on_exit(fn ->
      File.rm(Path.join(static, rel_wide))
      File.rm(Path.join(static, rel_tall))
    end)

    # The split is side-by-side only, so a portrait sheet is the shape that
    # warrants the toggle warning; a wide (landscape/spread) sheet does not.
    assert RulebookDownloader.portrait_sheet?(rel_tall)
    refute RulebookDownloader.portrait_sheet?(rel_wide)
    # A missing file must not warn (don't guess on uncertainty).
    refute RulebookDownloader.portrait_sheet?("uploads/rulebooks/does_not_exist.pdf")
  end
end
