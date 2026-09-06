defmodule RuleMaven.PromptsInlineGlyphTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Prompts

  # Horrified: D&D p.10 prints "At Mimic's location, discard (6+) to battle
  # Mimic and defeat it!" — the 6+ is a blue token glyph set inline in the
  # sentence. The transcription prompt said only "do NOT describe images", so
  # the reader improvised a NAME for it and guessed wrong: "[sword icon]". The
  # ask pipeline then answered, in good faith, that you discard "any Item with
  # a sword icon (Weapon)" — a rule the book does not contain, cited to a real
  # page (2026-09-05).
  #
  # An inline glyph carrying printed characters is rules text, not art. These
  # tests pin the instruction that says so, in both the reader and the critic
  # that is supposed to catch the reader.

  describe "vision_transcribe" do
    test "distinguishes inline glyphs from decorative art" do
      t = Prompts.default("vision_transcribe")

      assert t =~ ~r/inline/i,
             "must address glyphs set inline in a sentence"

      assert t =~ ~r/never\s+guess\s+a\s+name/i,
             "must forbid guessing an iconographic name"
    end

    test "requires the characters printed inside a glyph to be transcribed" do
      t = Prompts.default("vision_transcribe")

      assert t =~ ~r/printed\s+inside/i,
             "must say to transcribe the characters printed inside the glyph"
    end
  end

  describe "vision_critic" do
    test "has a defect class for a misread glyph" do
      assert Prompts.default("vision_critic") =~ ~r/\bGLYPH\b/,
             "critic must be able to name a glyph defect, or it cannot catch one"
    end
  end
end
