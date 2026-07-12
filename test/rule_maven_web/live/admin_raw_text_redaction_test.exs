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

    test "scalar columns show for a plain admin; free-text ones mask (default-deny)" do
      # `id` (integer) is shown by type; `name` (text) masks — a game title reads
      # harmless but the same bare column name is `groups.name`, a crew name that
      # can carry real people, so default-deny masks all `name` columns.
      rows = [%{"id" => 1, "name" => "Catan"}]

      assert [%{"id" => 1, "name" => "«redacted»"}] = Db.__redact_for_test__(rows, "games", false)
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

    test "masks answer_voices.content — the persona restyle is the same prose in a costume" do
      # answer_voices holds the persona restyle of a crew answer (fact/length
      # parity preserved), keyed only by (question_log_id, voice) with no crew
      # gate on write — so reading it verbatim bypasses listed_answer entirely.
      rows = [%{"id" => 1, "voice" => "pirate", "content" => "Arr, Sarah be caught."}]

      masked = Db.__redact_for_test__(rows, "answer_voices", false)

      assert [%{"content" => "«redacted»", "voice" => "pirate", "id" => 1}] = masked
      refute inspect(masked) =~ "Sarah"
    end

    test "a superadmin's answer_voices read is untouched" do
      rows = [%{"id" => 1, "content" => "Arr, Sarah be caught."}]

      assert ^rows = Db.__redact_for_test__(rows, "answer_voices", true)
    end

    test "masks house_rule_deltas.delta — the note restates the crew Q&A" do
      rows = [%{"id" => 1, "delta" => "With your rule, Sarah's card is now legal."}]

      masked = Db.__redact_for_test__(rows, "house_rule_deltas", false)

      assert [%{"delta" => "«redacted»", "id" => 1}] = masked
      refute inspect(masked) =~ "Sarah"
    end

    test "masks groups.invite_code — reading it lets an admin join the crew" do
      rows = [
        %{"id" => 1, "name" => "Dave & Mike's Catan Night", "invite_code" => "SECRETJOINCODE"}
      ]

      masked = Db.__redact_for_test__(rows, "groups", false)

      # Both the join secret AND the crew name (which can carry real people) mask.
      assert [%{"invite_code" => "«redacted»", "name" => "«redacted»", "id" => 1}] = masked
    end

    test "masks question_flags.reason — reporter free-text can name real people" do
      rows = [%{"id" => 1, "reason" => "wrong, Dave never rolled that"}]

      masked = Db.__redact_for_test__(rows, "question_flags", false)

      assert [%{"reason" => "«redacted»", "id" => 1}] = masked
    end

    test "default-deny masks PII/credentials on users, but shows identifiers" do
      # These were never in any denylist — default-deny by column TYPE catches them:
      # email/password_hash are text, so masked; username/role/id are safe.
      rows = [
        %{
          "id" => 1,
          "username" => "alice",
          "role" => "admin",
          "email" => "alice@secret.com",
          "password_hash" => "$2b$04$abcdefghijklmnopqrstuv"
        }
      ]

      masked = Db.__redact_for_test__(rows, "users", false)

      assert [
               %{
                 "id" => 1,
                 "username" => "alice",
                 "role" => "admin",
                 "email" => "«redacted»",
                 "password_hash" => "«redacted»"
               }
             ] = masked
    end

    test "default-deny masks canonical_question — the question twin of canonical_answer" do
      # The old denylist masked canonical_answer but missed canonical_question;
      # default-deny by type catches it with no per-column bookkeeping.
      rows = [%{"id" => 1, "canonical_question" => "Can Dave cheat here?"}]

      masked = Db.__redact_for_test__(rows, "questions_log", false)

      assert [%{"canonical_question" => "«redacted»", "id" => 1}] = masked
    end
  end
end
