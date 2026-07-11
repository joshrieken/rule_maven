defmodule RuleMavenWeb.AdminRawTextRedactionTest do
  @moduledoc """
  The crew threat model: even an admin must not read another user's RAW crew
  wording (a crew question can name real people). Purpose-built admin surfaces
  scrub it; these two ancillary channels leaked it a key-name / read-scope away.
  """
  use RuleMaven.DataCase, async: true

  alias RuleMavenWeb.AdminLive.{Audit, Db}

  describe "audit format_meta redaction" do
    test "drops the short key `cleaned` that ask_verbatim actually writes" do
      # The writer stores `%{\"original\" => raw, \"cleaned\" => cleaned_question}`.
      # On a normalize FALLBACK, `cleaned_question` holds the asker's raw prose, so
      # rendering `cleaned=...` in the audit Details column leaked it. The redaction
      # list keyed on canonical column names and missed the short key.
      meta = %{
        "original" => "Dave's rogue?",
        "cleaned" => "Dave's rogue?",
        "table" => "questions_log"
      }

      out = Audit.__format_meta_for_test__(meta)

      refute out =~ "Dave"
      assert out =~ "table=questions_log"
    end
  end

  describe "/admin/db sensitive-column masking" do
    test "a plain admin's read masks raw question columns" do
      rows = [%{"id" => 1, "question" => "Dave's rogue?", "cleaned_question" => "Dave's rogue?"}]

      masked = Db.__redact_for_test__(rows, "questions_log", false)

      assert [%{"question" => "«redacted»", "cleaned_question" => "«redacted»", "id" => 1}] =
               masked
    end

    test "a superadmin's read is untouched" do
      rows = [%{"id" => 1, "question" => "Dave's rogue?"}]

      assert ^rows = Db.__redact_for_test__(rows, "questions_log", true)
    end

    test "a non-sensitive table is untouched for a plain admin" do
      rows = [%{"id" => 1, "name" => "Catan"}]

      assert ^rows = Db.__redact_for_test__(rows, "games", false)
    end

    test "a nil value is left nil, not masked" do
      rows = [%{"id" => 1, "question" => nil}]

      assert [%{"question" => nil}] = Db.__redact_for_test__(rows, "questions_log", false)
    end

    test "masks the answer columns too — a crew answer echoes the withheld question" do
      # Masking `question`/`raw_response` but leaving `answer` rendered raw leaks
      # the same crew prose one column over ("No, Sarah can't palm a card").
      rows = [
        %{
          "id" => 1,
          "answer" => "No, Sarah can't palm a card.",
          "canonical_answer" => "No — palming is not allowed."
        }
      ]

      masked = Db.__redact_for_test__(rows, "questions_log", false)

      assert [%{"answer" => "«redacted»", "canonical_answer" => "«redacted»", "id" => 1}] = masked
      refute inspect(masked) =~ "Sarah"
    end
  end
end
