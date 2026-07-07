defmodule RuleMaven.PromptsLanguageGuardTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Prompts

  # The default model (deepseek) occasionally drifts into Chinese on English
  # input (2026-07-07 incident). Every prompt whose output is user-facing or
  # parsed prose must carry an explicit English rule; transcription/cleanup
  # prompts instead pin the source text's own language (never translate).
  # This test pins the guard so a future prompt edit can't silently drop it.

  @english_keys ~w(
    answer
    normalize_question_system
    pool_tiebreaker_system
    vision_critic
    cleanup_critic
    grounding_critic
    house_rule_check_system
    house_rule_delta_system
    suggest_questions_system
    did_you_know_system
    categories_system
    setup_generate_system
    expansion_delta_system
    voice_restyle_system
    generate_voices_system
    cheat_compress_system
    cheat_generate_system
    suspicious_answer_retry
  )

  @keep_source_keys ~w(cleanup_light cleanup_standard cleanup_aggressive vision_transcribe)

  # Fixed-token outputs (numbers / `none`) — the guard is a "no prose in any
  # language" clause rather than an English-prose rule.
  @no_prose_keys ~w(setup_verify did_you_know_verify did_you_know_verify_system)

  test "user-facing / parsed prompts require English output" do
    for key <- @english_keys do
      assert Prompts.default(key) =~ ~r/English/i,
             "prompt default #{key} lost its English-language rule"
    end
  end

  test "transcription/cleanup prompts pin the source language and forbid translation" do
    for key <- @keep_source_keys do
      assert Prompts.default(key) =~ ~r/original (printed )?language/i,
             "prompt default #{key} lost its keep-source-language rule"

      assert Prompts.default(key) =~ ~r/translate/i,
             "prompt default #{key} lost its never-translate rule"
    end
  end

  test "fixed-format verifier prompts forbid prose in any language" do
    for key <- @no_prose_keys do
      assert Prompts.default(key) =~ ~r/any language|in the requested format/i,
             "prompt default #{key} lost its no-prose guard"
    end
  end
end
