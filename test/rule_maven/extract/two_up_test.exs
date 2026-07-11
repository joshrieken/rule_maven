defmodule RuleMaven.Extract.TwoUpTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.TwoUp

  describe "map_page/1" do
    test "odd logical pages are the left half of their sheet" do
      assert TwoUp.map_page(1) == {1, :left}
      assert TwoUp.map_page(3) == {2, :left}
      assert TwoUp.map_page(11) == {6, :left}
    end

    test "even logical pages are the right half of their sheet" do
      assert TwoUp.map_page(2) == {1, :right}
      assert TwoUp.map_page(4) == {2, :right}
      assert TwoUp.map_page(12) == {6, :right}
    end
  end

  describe "logical_count/1" do
    test "doubles the sheet count" do
      assert TwoUp.logical_count(0) == 0
      assert TwoUp.logical_count(7) == 14
    end
  end

  describe "crop_args/4" do
    test "left half starts at x=0 with half the rendered width" do
      # US Letter landscape spread: 1224 x 792 pts at 300 dpi → 5100 x 3300 px.
      assert TwoUp.crop_args(1224.0, 792.0, 300, :left) ==
               ["-x", "0", "-y", "0", "-W", "2550", "-H", "3300"]
    end

    test "right half starts at the midpoint and takes the remainder" do
      assert TwoUp.crop_args(1224.0, 792.0, 300, :right) ==
               ["-x", "2550", "-y", "0", "-W", "2550", "-H", "3300"]
    end

    test "odd pixel widths give the right half the extra pixel" do
      # 841 pts at 72 dpi → 841 px: left gets 420, right gets 421.
      assert TwoUp.crop_args(841.0, 595.28, 72, :left) ==
               ["-x", "0", "-y", "0", "-W", "420", "-H", "595"]

      assert TwoUp.crop_args(841.0, 595.28, 72, :right) ==
               ["-x", "420", "-y", "0", "-W", "421", "-H", "595"]
    end
  end

  describe "sheet_size parsing" do
    test "reads per-sheet dimensions from pdfinfo output" do
      out = """
      Producer:        magick
      Page    3 size:  1224 x 792 pts
      Page    3 rot:   0
      File size:       12345 bytes
      """

      assert TwoUp.parse_sheet_size(out, 3) == {:ok, {1224.0, 792.0}}
    end

    test "swaps dimensions for 90/270-rotated sheets (scanner output)" do
      # pdfinfo reports the unrotated media box; poppler renders after /Rotate,
      # so a portrait media box rotated 90° renders landscape.
      out = """
      Page    1 size:  612 x 792 pts
      Page    1 rot:   90
      Page    2 size:  612 x 792 pts
      Page    2 rot:   270
      Page    3 size:  612 x 792 pts
      Page    3 rot:   180
      """

      assert TwoUp.parse_sheet_size(out, 1) == {:ok, {792.0, 612.0}}
      assert TwoUp.parse_sheet_size(out, 2) == {:ok, {792.0, 612.0}}
      assert TwoUp.parse_sheet_size(out, 3) == {:ok, {612.0, 792.0}}
    end

    test "missing rot line means no rotation" do
      out = "Page    1 size:  842 x 595 pts\n"
      assert TwoUp.parse_sheet_size(out, 1) == {:ok, {842.0, 595.0}}
    end

    test "errors when the size line is missing" do
      assert TwoUp.parse_sheet_size("nonsense", 2) == {:error, :no_size}
    end
  end
end
