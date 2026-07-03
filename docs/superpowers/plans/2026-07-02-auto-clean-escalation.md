# Auto-Escalating Cleanup Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-page closed cleanup loop — clean at standard, verify cheaply, escalate/de-escalate once, persist best attempt — replacing the fixed light/standard/aggressive picker.

**Architecture:** New pure `RuleMaven.Extract.CleanCheck` module scores each clean attempt with free heuristics; only suspects pay for an LLM critic call whose typed verdict (`faithful` / `junk_remains` / `content_lost`) drives at most one retry at a different level. The loop lives in `CleanupWorker.clean_one`; `LLM.cleanup_page` stays single-shot but gains a soft drop-guard mode so the critic (not a length ratio) adjudicates short outputs. UI collapses to a single Clean action enqueuing `level: "auto"`.

**Tech Stack:** Elixir/Phoenix LiveView, Oban, existing `:llm_mock` test stub.

Spec: `docs/superpowers/specs/2026-07-02-auto-clean-escalation-design.md`

## Global Constraints

- LLM prompts live in the editable Prompts registry (`RuleMaven.Prompts`), never hardcoded in call sites.
- Critic failure must never block or revert a cleanup (existing invariant).
- Worker must stay restart-resumable: only winning attempt persists; failed pages leave `cleaned` nil.
- Worker keeps accepting explicit `"light"|"standard"|"aggressive"` levels (mix tasks, queued jobs); those run the legacy single-shot path.
- Tee test output to `./tmp/<name>.log`; don't run the full suite twice; delete the log when done.
- Commit after each task (auto-commit rule).

---

### Task 1: `Extract.CleanCheck` heuristic verdict module

**Files:**
- Create: `lib/rule_maven/extract/clean_check.ex`
- Test: `test/rule_maven/extract/clean_check_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Extract.Gate.wordish_ratio/1`, `Gate.tokens/1` (existing).
- Produces: `CleanCheck.check(raw, cleaned, level, status) :: :accept | {:suspect, :under | :over | :both}` where `level in [:light, :standard, :aggressive]` and `status in [:cleaned, :unchanged, :kept_raw, :guard_fired, :empty]`. Also `CleanCheck.garble_lines(text) :: non_neg_integer` (used in tests/log).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/rule_maven/extract/clean_check_test.exs
defmodule RuleMaven.Extract.CleanCheckTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.CleanCheck

  @clean_prose """
  Each player draws five cards at the start of the game and keeps them hidden.
  On your turn you may play one card and then move your pawn up to three spaces.
  """

  @garbled """
  Each player draws five cards at the start of the game and keeps them hidden.
  ~~ %% §§ x7 qq zz ##" ]] [[ ø ø ø
  On your turn you may play one card and then move your pawn up to three spaces.
  """

  test "empty status accepts (blank page)" do
    assert CleanCheck.check("", "", :standard, :empty) == :accept
  end

  test "guard_fired is always suspect over" do
    assert CleanCheck.check(@clean_prose, "Each player draws.", :standard, :guard_fired) ==
             {:suspect, :over}
  end

  test "unchanged on clean input accepts" do
    assert CleanCheck.check(@clean_prose, @clean_prose, :standard, :unchanged) == :accept
  end

  test "unchanged on junky input is suspect under" do
    assert CleanCheck.check(@garbled, @garbled, :standard, :unchanged) == {:suspect, :under}
  end

  test "cleaned output inside envelope with no garble accepts" do
    # ~11% shrink at standard (envelope allows up to 30%).
    cleaned = String.slice(@clean_prose, 0, round(String.length(@clean_prose) * 0.89))
    assert CleanCheck.check(@clean_prose, cleaned, :standard, :cleaned) == :accept
  end

  test "surviving garble lines are suspect under" do
    assert CleanCheck.check(@garbled, @garbled <> " tidied", :standard, :cleaned) ==
             {:suspect, :under}
  end

  test "huge shrink at light is suspect over" do
    cleaned = String.slice(@clean_prose, 0, round(String.length(@clean_prose) * 0.5))
    assert CleanCheck.check(@clean_prose, cleaned, :light, :cleaned) == {:suspect, :over}
  end

  test "under-shrink at aggressive is suspect under" do
    # Aggressive is meant to cut ≥10%; an output identical in size didn't cut.
    assert CleanCheck.check(@clean_prose, @clean_prose <> " ", :aggressive, :cleaned) ==
             {:suspect, :under}
  end

  test "both signals combine to :both" do
    # Garble survives AND shrink beyond light's 15% cap.
    out = "~~ %% §§ x7 qq zz ##\nshort"
    assert CleanCheck.check(@clean_prose, out, :light, :cleaned) == {:suspect, :both}
  end

  test "garble_lines counts low-wordish lines with enough tokens" do
    assert CleanCheck.garble_lines(@garbled) == 1
    assert CleanCheck.garble_lines(@clean_prose) == 0
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/extract/clean_check_test.exs 2>&1 | tee tmp/clean_check.log`
Expected: FAIL — module `RuleMaven.Extract.CleanCheck` is not available.

- [ ] **Step 3: Implement the module**

```elixir
# lib/rule_maven/extract/clean_check.ex
defmodule RuleMaven.Extract.CleanCheck do
  @moduledoc """
  Free, deterministic verdict on one page-cleanup attempt — the cheap first
  tier of the auto-clean loop. `:accept` means the attempt looks sound and no
  LLM critic call is needed; `{:suspect, direction}` routes the attempt to the
  critic, whose typed verdict decides escalation. Suspicion is cheap (one extra
  LLM call), a wrong accept is not — so borderline cases lean suspect, mirroring
  `Extract.Gate`'s recall bias.

  Directions: `:under` — the clean was too gentle (garble survived, junky input
  returned unchanged, aggressive barely cut); `:over` — it cut too hard (shrink
  beyond the level's envelope, drop guard fired); `:both` when both fire.
  """

  alias RuleMaven.Extract.Gate

  # A line is "garble" when it has enough tokens to judge and almost none look
  # like words — OCR symbol soup a cleaner should have fixed or removed.
  @garble_line_wordish 0.3
  @garble_min_tokens 3

  # Acceptable shrink fraction (in-out)/in per level. Negative = growth (a
  # little reflow growth is normal). Outside the envelope is suspect: below the
  # floor the level didn't do its job (:under), above the cap it cut into
  # content (:over).
  @envelopes %{light: {-0.10, 0.15}, standard: {-0.10, 0.30}, aggressive: {0.0, 0.70}}

  @doc """
  Score one clean attempt. `status` is `LLM.cleanup_page`'s status atom
  (`:guard_fired` is the soft-guard variant of `:kept_raw`).
  Returns `:accept` or `{:suspect, :under | :over | :both}`.
  """
  def check(_raw, _cleaned, _level, :empty), do: :accept
  def check(_raw, _cleaned, _level, :guard_fired), do: {:suspect, :over}
  # Legacy hard-guard revert: raw was kept, nothing to judge — accept as-is.
  def check(_raw, _cleaned, _level, :kept_raw), do: :accept

  def check(raw, _cleaned, _level, :unchanged) do
    if junky?(raw), do: {:suspect, :under}, else: :accept
  end

  def check(raw, cleaned, level, :cleaned) do
    {min_shrink, max_shrink} = Map.fetch!(@envelopes, level)
    shrink = shrink(raw, cleaned)

    under? = garble_lines(cleaned) > 0 or shrink < min_shrink
    over? = shrink > max_shrink

    cond do
      under? and over? -> {:suspect, :both}
      under? -> {:suspect, :under}
      over? -> {:suspect, :over}
      true -> :accept
    end
  end

  @doc "Count of symbol-soup lines a cleaner should have fixed or dropped."
  def garble_lines(text) do
    (text || "")
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      length(Gate.tokens(line)) >= @garble_min_tokens and
        Gate.wordish_ratio(line) < @garble_line_wordish
    end)
  end

  # Junky raw text: garble present or overall wordishness low — a page a
  # cleaner returning it verbatim almost certainly under-cleaned.
  defp junky?(raw), do: garble_lines(raw) > 0 or Gate.wordish_ratio(raw) < 0.6

  defp shrink(raw, cleaned) do
    in_len = String.length(String.trim(raw || ""))
    out_len = String.length(String.trim(cleaned || ""))
    if in_len == 0, do: 0.0, else: (in_len - out_len) / in_len
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/extract/clean_check_test.exs 2>&1 | tee tmp/clean_check.log`
Expected: PASS (10 tests). Then `rm tmp/clean_check.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/extract/clean_check.ex test/rule_maven/extract/clean_check_test.exs
git commit -m "feat: CleanCheck heuristic verdict module for auto-clean loop"
```

---

### Task 2: Typed critic verdict

**Files:**
- Modify: `lib/rule_maven/prompts.ex` (the `@cleanup_critic` module attribute, ~line 217)
- Modify: `lib/rule_maven/llm.ex` (`critique_cleanup/3`, ~line 370)
- Modify: `lib/rule_maven/workers/cleanup_worker.ex` (`maybe_critique/5`, ~line 215 — keep compiling; full rework in Task 4)
- Test: `test/rule_maven/llm_cleanup_critic_test.exs` (create)

**Interfaces:**
- Consumes: `LLM.parse_defects/1` (existing, unchanged — still used by the vision critic).
- Produces: `LLM.critique_cleanup(raw, cleaned, opts) :: {:ok, %{verdict: :faithful | :junk_remains | :content_lost, defects: [String.t()]}} | {:error, term}` and `LLM.parse_critic_verdict(text) :: %{verdict: ..., defects: [...]}` (public for tests).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/rule_maven/llm_cleanup_critic_test.exs
defmodule RuleMaven.LLMCleanupCriticTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  test "parses verdict line plus defect bullets" do
    text = """
    VERDICT: junk_remains
    - GARBLE: "~~ %% §§" still present mid-page
    - HEADER: running title not removed
    """

    assert LLM.parse_critic_verdict(text) == %{
             verdict: :junk_remains,
             defects: [
               ~s(- GARBLE: "~~ %% §§" still present mid-page),
               "- HEADER: running title not removed"
             ]
           }
  end

  test "verdict is case/spacing tolerant" do
    assert %{verdict: :content_lost} = LLM.parse_critic_verdict("verdict:  Content_Lost\n- DROPPED: setup step 3")
  end

  test "faithful verdict with NONE yields no defects" do
    assert LLM.parse_critic_verdict("VERDICT: faithful\nNONE") == %{verdict: :faithful, defects: []}
  end

  test "missing verdict line falls back to faithful (critic never blocks)" do
    assert %{verdict: :faithful} = LLM.parse_critic_verdict("- DROPPED: something")
    assert %{verdict: :faithful} = LLM.parse_critic_verdict("")
  end

  test "critique_cleanup returns the parsed verdict map" do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "VERDICT: content_lost\n- DROPPED: the tiebreaker rule"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :content_lost, defects: ["- DROPPED: the tiebreaker rule"]}} =
             LLM.critique_cleanup("raw text", "cleaned text")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_cleanup_critic_test.exs 2>&1 | tee tmp/critic.log`
Expected: FAIL — `parse_critic_verdict/1` undefined.

- [ ] **Step 3: Rewrite the `@cleanup_critic` prompt default**

In `lib/rule_maven/prompts.ex`, replace the whole `@cleanup_critic` attribute with:

```elixir
@cleanup_critic """
You are an adversarial reviewer checking a CLEANED version of one rulebook page
against its RAW extraction. Cleanup is allowed to fix OCR/layout noise (broken
line wraps, stray hyphens, headers/footers, page numbers, garbled characters,
de-interleaved columns) but MUST NOT drop or alter actual rule content, and it
SHOULD have removed obvious OCR garble and layout junk.

First output exactly one verdict line:

VERDICT: faithful | junk_remains | content_lost

- faithful — all rule content preserved AND no obvious junk/garble remains.
- junk_remains — rule content is preserved but OCR garble, headers/footers, or
  layout junk survived that a cleaner should have removed.
- content_lost — a rule, number, step, condition, table row, or example present
  in RAW is missing from or contradicted in CLEANED (this outranks junk_remains
  if both apply).

Then list concrete, specific defects, one per line:

- DROPPED: a rule, number, step, condition, table row, or example present in
  RAW but missing from CLEANED.
- CHANGED: a value, count, name, or wording in CLEANED that contradicts RAW.
- INVENTED: rule text in CLEANED that is not supported by RAW.
- GARBLE: OCR symbol soup or corrupted text that survived cleanup.
- JUNK: a header, footer, or non-rule layout artifact that survived cleanup.

Ignore pure formatting differences and removed page numbers/headers — those are
the job of cleanup. Quote the affected text so each defect is actionable. If
the verdict is faithful, output exactly NONE after the verdict line.
"""
```

Update the registry entry's `description` (same file, `key: "cleanup_critic"`) to:

```elixir
      description:
        "Typed verdict (faithful/junk_remains/content_lost) + defect list; drives the auto-clean escalation loop.",
```

- [ ] **Step 4: Update `critique_cleanup` and add the parser**

In `lib/rule_maven/llm.ex`, replace `critique_cleanup/3`'s doc + success clause and add `parse_critic_verdict/1` right after `parse_defects/1`:

```elixir
  @doc """
  Adversarial check that a page's cleanup preserved its rule content. Given the
  raw extraction and the cleaned text, returns `{:ok, %{verdict, defects}}`
  where `verdict` is `:faithful | :junk_remains | :content_lost` and `defects`
  is a list of concrete defect lines. Uses the cleanup model by default
  (text-only, cheap). Callers treat an error as faithful — a critic failure
  must never block or revert a cleanup.
  """
  def critique_cleanup(raw, cleaned, opts \\ []) do
    user =
      "RAW EXTRACTION:\n\n" <> (raw || "") <> "\n\n---\n\nCLEANED VERSION:\n\n" <> (cleaned || "")

    case chat(user, "cleanup_critic",
           system: RuleMaven.Prompts.template("cleanup_critic"),
           max_tokens: 1024,
           model: opts[:model] || model(:cleanup),
           operation: "cleanup",
           game_id: opts[:game_id]
         ) do
      {:ok, text} -> {:ok, parse_critic_verdict(text)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses a typed cleanup-critic reply: a `VERDICT: <word>` line plus defect
  lines (parsed by `parse_defects/1`, so NONE/blank handling matches the vision
  critic). A missing or unrecognized verdict falls back to `:faithful` — the
  critic must never block a cleanup on a malformed reply (e.g. an admin's
  older prompt override without the verdict line).
  """
  def parse_critic_verdict(text) do
    trimmed = String.trim(text || "")

    verdict =
      case Regex.run(~r/^\s*verdict:\s*(faithful|junk_remains|content_lost)\b/im, trimmed) do
        [_, v] -> String.to_existing_atom(String.downcase(v))
        _ -> :faithful
      end

    defects =
      trimmed
      |> String.replace(~r/^\s*verdict:.*$/im, "")
      |> parse_defects()

    %{verdict: verdict, defects: defects}
  end
```

Note: `:junk_remains` and `:content_lost` atoms are compiled literals in this
function (the `case` above references them only via `to_existing_atom`), so
add this line above `parse_critic_verdict/1` to guarantee they exist:

```elixir
  @critic_verdicts [:faithful, :junk_remains, :content_lost]
  def critic_verdicts, do: @critic_verdicts
```

- [ ] **Step 5: Keep `CleanupWorker` compiling**

In `lib/rule_maven/workers/cleanup_worker.ex`, `maybe_critique/5` destructures the old return. Change the first clause body to:

```elixir
  defp maybe_critique(true, :cleaned, body, text, game_id) do
    case RuleMaven.LLM.critique_cleanup(body, text, game_id: game_id) do
      {:ok, %{defects: defects}} -> defects
      {:error, _} -> []
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_cleanup_critic_test.exs test/rule_maven/extract/critic_test.exs test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tee tmp/critic.log`
Expected: PASS (critic_test.exs covers the vision-critic `parse_defects`, unchanged). Then `rm tmp/critic.log`.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/prompts.ex lib/rule_maven/llm.ex lib/rule_maven/workers/cleanup_worker.ex test/rule_maven/llm_cleanup_critic_test.exs
git commit -m "feat: typed verdict (faithful/junk_remains/content_lost) from cleanup critic"
```

---

### Task 3: Soft drop guard in `LLM.cleanup_page`

**Files:**
- Modify: `lib/rule_maven/llm.ex` (`cleanup_page/4`, ~line 332)
- Test: `test/rule_maven/llm_cleanup_guard_test.exs` (create)

**Interfaces:**
- Produces: `cleanup_page(text, level, page_number, opts)` accepting `soft_guard: true`. With it, a below-floor **non-empty** output returns `{:ok, output, :guard_fired}` (output kept for the critic to adjudicate). Empty output still reverts to `{:ok, raw, :kept_raw}` (nothing to adjudicate). Without the opt, behavior is unchanged (`:kept_raw` revert).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/rule_maven/llm_cleanup_guard_test.exs
defmodule RuleMaven.LLMCleanupGuardTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  @raw String.duplicate("every word of this rule matters a lot ", 10)

  defp mock(answer) do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:ok, %{answer: answer}} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  test "hard guard (default) reverts a too-short output to raw" do
    mock("tiny")
    assert {:ok, @raw, :kept_raw} = LLM.cleanup_page(@raw, :light)
  end

  test "soft guard keeps a too-short output and reports :guard_fired" do
    mock("tiny")
    assert {:ok, "tiny", :guard_fired} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end

  test "soft guard still reverts an empty output to raw" do
    mock("   ")
    assert {:ok, @raw, :kept_raw} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end

  test "output above the floor is :cleaned either way" do
    mock(String.upcase(@raw))
    assert {:ok, _, :cleaned} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven/llm_cleanup_guard_test.exs 2>&1 | tee tmp/guard.log`
Expected: FAIL — soft-guard case returns `:kept_raw` with raw text.

- [ ] **Step 3: Implement**

In `cleanup_page/4`, replace the guard block:

```elixir
        {:ok, cleaned} ->
          trimmed = String.trim(cleaned)
          min_keep = round(String.length(page_text) * min_kept_ratio(level))

          # Output collapsed below the length floor → likely truncation/refusal.
          # Hard guard (default): keep the raw page (:kept_raw). Soft guard
          # (auto-clean loop): keep the short output and report :guard_fired so
          # the critic can adjudicate — an aggressive clean of a junk-heavy page
          # legitimately shrinks past the floor, and blanket reverts were baking
          # raw junk back in. An empty output has nothing to adjudicate and
          # reverts either way.
          cond do
            trimmed == "" -> {:ok, page_text, :kept_raw}
            String.length(trimmed) >= min_keep -> {:ok, cleaned, :cleaned}
            opts[:soft_guard] -> {:ok, cleaned, :guard_fired}
            true -> {:ok, page_text, :kept_raw}
          end
```

Update the `@doc` for `cleanup_page` to mention `soft_guard: true` and the `:guard_fired` status.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven/llm_cleanup_guard_test.exs 2>&1 | tee tmp/guard.log`
Expected: PASS. Then `rm tmp/guard.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex test/rule_maven/llm_cleanup_guard_test.exs
git commit -m "feat: soft drop guard option on cleanup_page for critic adjudication"
```

---

### Task 4: Auto-escalation loop in `CleanupWorker`

**Files:**
- Modify: `lib/rule_maven/workers/cleanup_worker.ex`
- Test: `test/rule_maven/workers/cleanup_worker_test.exs` (extend)

**Interfaces:**
- Consumes: `CleanCheck.check/4` (Task 1), `LLM.critique_cleanup/3` → `{:ok, %{verdict, defects}}` (Task 2), `LLM.cleanup_page(..., soft_guard: true)` → `:guard_fired` (Task 3).
- Produces: worker accepts `"level" => "auto"` (and it becomes the fallback for unknown levels). Job-log page lines include the level path, e.g. `Cleaned page 12 (standard→aggressive) — 1840→1211 chars (−34%) · 3/20 done`. Meta map gains `:path` (string) and keeps `:defects`.

- [ ] **Step 1: Write the failing tests**

Append to `test/rule_maven/workers/cleanup_worker_test.exs`. The scripted mock
distinguishes critic calls (system prompt contains "adversarial reviewer") from
clean calls, and clean levels via prompt overrides installed as Settings
(`Prompts.template/1` returns the override).

```elixir
  # ── Auto-escalation loop ──

  # Distinct system prompts per level so the mock can tell attempts apart, and
  # a scripted responder: cleans answer from `script` keyed by level marker,
  # critic answers popped from the `critic` list (in call order).
  defp install_auto_mock(script, critic_replies) do
    RuleMaven.Settings.put("prompt_cleanup_light", "MARK_LIGHT clean the page")
    RuleMaven.Settings.put("prompt_cleanup_standard", "MARK_STANDARD clean the page")
    RuleMaven.Settings.put("prompt_cleanup_aggressive", "MARK_AGGRESSIVE clean the page")

    {:ok, agent} = Agent.start_link(fn -> %{critic: critic_replies, calls: []} end)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      system =
        body.messages
        |> Enum.find(&(&1.role == "system" or &1[:role] == "system"))
        |> then(&(&1 && (&1[:content] || &1.content))) || ""

      cond do
        system =~ "adversarial reviewer" ->
          Agent.get_and_update(agent, fn %{critic: [h | t]} = s ->
            {{:ok, %{answer: h}}, %{s | critic: t, calls: s.calls ++ [:critic]}}
          end)

        system =~ "MARK_LIGHT" ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:light]})
          {:ok, %{answer: script.light}}

        system =~ "MARK_AGGRESSIVE" ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:aggressive]})
          {:ok, %{answer: script.aggressive}}

        true ->
          Agent.update(agent, &%{&1 | calls: &1.calls ++ [:standard]})
          {:ok, %{answer: script.standard}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    agent
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  @good_page "Each player draws five cards at the start of the game and keeps them hidden. On your turn you may play one card and then move your pawn up to three spaces."
  @garbled_page @good_page <> "\n~~ %% §§ x7 qq zz ##"
  @good_clean String.upcase(@good_page)

  test "auto: clean page accepts at standard with no critic call" do
    agent = install_auto_mock(%{standard: @good_clean, light: "L", aggressive: "A"}, [])
    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard]
  end

  test "auto: junk_remains escalates to aggressive and keeps the faithful retry" do
    # Standard "clean" leaves the garble in → heuristic suspect → critic says
    # junk_remains → retry aggressive → clean output → critic faithful.
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " tidied", light: "L", aggressive: @good_clean},
        ["VERDICT: junk_remains\n- GARBLE: \"~~ %%\" survived", "VERDICT: faithful\nNONE"]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard, :critic, :aggressive, :critic]
  end

  test "auto: content_lost de-escalates to light" do
    # Standard cut too hard (beyond envelope) → critic content_lost → retry
    # light → faithful.
    short = String.slice(@good_clean, 0, div(String.length(@good_clean), 2))

    agent =
      install_auto_mock(
        %{standard: short, light: @good_clean, aggressive: "A"},
        ["VERDICT: content_lost\n- DROPPED: pawn movement", "VERDICT: faithful\nNONE"]
      )

    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:standard, :critic, :light, :critic]
  end

  test "auto: guard-fired but faithful short output is accepted, not reverted" do
    # Aggressive-style legit big cut at standard: below the 0.5 floor, soft
    # guard keeps it, critic adjudicates faithful → accepted as-is.
    tiny = "Draw five cards. Play one card. Move three."

    agent =
      install_auto_mock(%{standard: tiny, light: "L", aggressive: "A"}, [
        "VERDICT: faithful\nNONE"
      ])

    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [tiny]
    assert calls(agent) == [:standard, :critic]
  end

  test "auto: still bad after retry keeps best attempt and flags the page" do
    # Both attempts junky; retry's verdict is also junk_remains → flag, keep
    # the attempt ranked best (equal verdicts → fewer defects wins: attempt 2).
    agent =
      install_auto_mock(
        %{standard: @garbled_page <> " a", light: "L", aggressive: @garbled_page <> " b"},
        [
          "VERDICT: junk_remains\n- GARBLE: soup\n- JUNK: header",
          "VERDICT: junk_remains\n- GARBLE: soup"
        ]
      )

    doc = doc_with_pages(@garbled_page)

    pages = run(doc, %{"level" => "auto"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@garbled_page <> " b"]
    assert calls(agent) == [:standard, :critic, :aggressive, :critic]
  end

  test "explicit level still runs the single-shot legacy path (no critic)" do
    agent = install_auto_mock(%{standard: "S", light: @good_clean, aggressive: "A"}, [])
    doc = doc_with_pages(@good_page)

    pages = run(doc, %{"level" => "light"}) |> Map.fetch!(:pages)

    assert Enum.map(pages, & &1.cleaned) == [@good_clean]
    assert calls(agent) == [:light]
  end
```

Also update the existing test `"an unknown level falls back to light instead of crashing"`: unknown levels now fall back to **auto**. Replace its body:

```elixir
  test "an unknown level falls back to auto instead of crashing" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")

    cleaned = run(doc, %{"level" => "bogus"}) |> Map.fetch!(:pages) |> Enum.map(& &1.cleaned)

    assert cleaned == ["ALPHA RULES HERE", "BETA RULES HERE"]
  end
```

(The default upcase mock output stays inside standard's envelope and is
garble-free, so auto accepts with no critic call — the assertion is unchanged.)

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `mix test test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tee tmp/worker.log`
Expected: new auto tests FAIL (`"auto"` parses to `:light` today; no loop); old tests PASS.

- [ ] **Step 3: Implement the loop**

In `lib/rule_maven/workers/cleanup_worker.ex`:

**3a.** Levels and moduledoc. Replace `@valid_levels ~w(light standard aggressive)` with:

```elixir
  @valid_levels ~w(auto light standard aggressive)
```

and change the fallback clause at the bottom:

```elixir
  defp parse_level(level) when level in @valid_levels, do: String.to_existing_atom(level)
  defp parse_level(_), do: :auto
```

(`:auto` must be a compiled literal — it is, via the clauses below.)

**3b.** Remove the critic Setting. Delete these lines from `perform/1`:

```elixir
    critic? = Settings.get("cleanup_critic") == "true"

    note = if critic?, do: " · critic on", else: ""
```

and change the start event to:

```elixir
    Jobs.event(run, "info", "Cleaning #{length(todo)} of #{total} pages (#{mode}, #{level})…")
```

Update the alias line (drop `Settings`):

```elixir
  alias RuleMaven.{Games, Jobs}
```

Change the `Task.async_stream` fn:

```elixir
        fn page -> {page.index, clean_one(page, level, mode, game_id)} end,
```

**3c.** Replace `clean_one/5` and `maybe_critique/5` (delete `maybe_critique` entirely) with:

```elixir
  alias RuleMaven.Extract.CleanCheck

  # Never let one page crash the job. Returns {:ok, cleaned, meta} on success or
  # :failed on any error — the caller leaves failed pages' `cleaned` nil so they
  # can be retried. `meta` carries in/out char counts, a status (:cleaned |
  # :unchanged | :kept_raw | :empty), the level `:path` taken, and `:defects`
  # (non-empty = page flagged for review).
  defp clean_one(page, level, mode, game_id) do
    body = if mode == "again", do: Games.effective_page_text(page), else: page.text || ""
    body = Games.strip_printed_number(body, page.printed)

    try do
      if level == :auto,
        do: clean_auto(body, page, game_id),
        else: clean_fixed(body, page, level, game_id)
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  # Legacy single-shot path for explicit levels (mix tasks, queued jobs).
  defp clean_fixed(body, page, level, game_id) do
    case RuleMaven.LLM.cleanup_page(body, level, page.printed, game_id: game_id) do
      {:ok, text, status} ->
        {:ok, text, body |> clean_meta(status, text) |> Map.put(:defects, [])}

      {:error, _} ->
        :failed
    end
  end

  # The auto loop: clean at :standard, judge cheaply, retry once in the
  # direction the critic indicates, persist the best attempt. Per-page budget:
  # ≤2 clean calls + ≤2 critic calls, paid only by suspect pages.
  defp clean_auto(body, page, game_id) do
    case attempt(body, :standard, page, game_id) do
      :failed ->
        :failed

      {:ok, first} ->
        case judge(body, first, game_id) do
          {:accept, first} ->
            finish(body, first, [first])

          {:retry, next_level, first} ->
            case attempt(body, next_level, page, game_id) do
              # Retry call failed — fall back to the judged first attempt.
              :failed ->
                finish(body, first, [first])

              {:ok, second} ->
                second = %{second | verdict: critic_verdict(body, second, game_id)}
                best = Enum.max_by([first, second], &rank/1)
                finish(body, best, [first, second])
            end
        end
    end
  end

  # One clean attempt at a concrete level. Soft guard: a below-floor output is
  # kept (:guard_fired) so the critic adjudicates instead of a blanket revert.
  defp attempt(body, level, page, game_id) do
    case RuleMaven.LLM.cleanup_page(body, level, page.printed,
           game_id: game_id,
           soft_guard: true
         ) do
      {:ok, text, status} ->
        {:ok, %{level: level, text: text, status: status, verdict: nil, defects: []}}

      {:error, _} ->
        :failed
    end
  end

  # Tier 1: free heuristics. Accept ends the page (no critic). Suspect pays one
  # critic call whose typed verdict picks the retry direction. Both outcomes
  # return the (possibly verdict-carrying) attempt so ranking/flagging can see
  # what the critic said.
  defp judge(body, att, game_id) do
    case CleanCheck.check(body, att.text, att.level, att.status) do
      :accept -> {:accept, att}
      {:suspect, _dir} -> accept_or_retry(body, att, game_id)
    end
  end

  defp accept_or_retry(body, att, game_id) do
    att = %{att | verdict: critic_verdict(body, att, game_id)}

    case att.verdict do
      %{verdict: :faithful} -> {:accept, att}
      %{verdict: :junk_remains} -> {:retry, :aggressive, att}
      %{verdict: :content_lost} -> {:retry, :light, att}
    end
  end

  # Critic failure never blocks: treat as faithful with no defects.
  defp critic_verdict(body, att, game_id) do
    case RuleMaven.LLM.critique_cleanup(body, att.text, game_id: game_id) do
      {:ok, verdict_map} -> verdict_map
      {:error, _} -> %{verdict: :faithful, defects: []}
    end
  end

  # Rank attempts: faithful beats any defect verdict; among equals, fewer
  # defects wins (Enum.max_by keeps the FIRST max on ties → the standard
  # attempt, the least surprising output).
  defp rank(%{verdict: nil}), do: {2, 0}
  defp rank(%{verdict: %{verdict: :faithful, defects: d}}), do: {2, -length(d)}
  defp rank(%{verdict: %{defects: d}}), do: {1, -length(d)}

  # Assemble the winning attempt's result. Defects flow into meta only when the
  # winner's verdict is still bad — that's what flags the page in the job log.
  defp finish(body, winner, attempts) do
    defects =
      case winner.verdict do
        %{verdict: v, defects: d} when v != :faithful -> d
        _ -> []
      end

    # :guard_fired means the critic accepted a legitimately short output — for
    # stats/log purposes that page was cleaned.
    status = if winner.status == :guard_fired, do: :cleaned, else: winner.status

    meta =
      body
      |> clean_meta(status, winner.text)
      |> Map.put(:defects, defects)
      |> Map.put(:path, Enum.map_join(attempts, "→", & &1.level))

    {:ok, winner.text, meta}
  end
```

Note: `judge/3` returns the verdict-carrying attempt (`{:accept, att}` /
`{:retry, level, att}`), so `clean_auto`'s rebinding of `first` after judging
picks up the critic verdict when one was paid for. A heuristic accept leaves
`verdict: nil`; `finish/3`'s `case winner.verdict` falls through to `[]`
defects for it, and `rank/1` scores both `nil` and faithful as top tier.

**3d.** `clean_meta` argument order changed above (`clean_meta(body, status, text)` reads better in pipes). Update its definition:

```elixir
  defp clean_meta(body, status, text) do
    in_len = String.length(body)
    out_len = String.length(text)

    status =
      cond do
        status in [:kept_raw, :empty] -> status
        String.trim(text) == String.trim(body) -> :unchanged
        true -> :cleaned
      end

    %{status: status, in: in_len, out: out_len}
  end
```

and `clean_fixed`'s call is already in the piped order shown in 3c.

**3e.** Level path in the job log. Change `page_event_msg` for `:cleaned`:

```elixir
  defp page_event_msg(index, %{status: :cleaned} = m, done, total) do
    path = if m[:path] && m.path != "standard", do: " (#{m.path})", else: ""

    "Cleaned page #{index + 1}#{path} — #{m.in}→#{m.out} chars (#{pct(m)}) · #{done}/#{total} done"
  end
```

**3f.** In `perform/1`'s reduce, `meta[:defects]` is already read — unchanged.

- [ ] **Step 4: Run the worker tests**

Run: `mix test test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tee tmp/worker.log`
Expected: PASS (all old + 6 new). Then `rm tmp/worker.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/workers/cleanup_worker.ex test/rule_maven/workers/cleanup_worker_test.exs
git commit -m "feat: auto-escalating per-page cleanup loop in CleanupWorker"
```

---

### Task 5: UI/callers switch to auto; remove level picker and critic setting

**Files:**
- Modify: `lib/rule_maven/games.ex` (`enqueue_cleanup/3` ~line 1323, `enqueue_cleanup_page/3` ~line 1340 — default `:auto`)
- Modify: `lib/rule_maven_web/live/game_live/form.ex` (remove picker + `clean_level` plumbing; enqueue `:auto`)
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex` (~line 276: `:light` → `:auto`)
- Modify: `lib/rule_maven/readiness.ex` (~line 371: `:light` → `:auto`)
- Modify: `lib/rule_maven_web/live/settings_live.ex` (remove `cleanup_critic` toggle: ~lines 112, 260, 336, 1020–1035)
- Modify: `priv/static/assets/js/app.js` (~lines 816, 829: remove `clean_level` connect param + `phx:save_clean_level` listener)
- Test: `test/rule_maven_web/prepare_render_test.exs`, `test/rule_maven_web/form_unextracted_source_test.exs` (run; fix only if they referenced the picker)

**Interfaces:**
- Consumes: worker's `"auto"` level (Task 4).
- Produces: `Games.enqueue_cleanup(doc, level \\ :auto, mode \\ :raw)`, `Games.enqueue_cleanup_page(doc, index, level \\ :auto)`.

- [ ] **Step 1: Change enqueue defaults**

In `lib/rule_maven/games.ex`, change both signatures and the `@doc` line
(`:auto | :light | :standard | :aggressive`; auto = escalation loop):

```elixir
  def enqueue_cleanup(%Document{} = doc, level \\ :auto, mode \\ :raw) do
```

```elixir
  def enqueue_cleanup_page(%Document{} = doc, index, level \\ :auto) do
```

- [ ] **Step 2: Point callers at auto**

- `lib/rule_maven_web/live/game_live/prepare.ex` line ~276: `Enum.each(pending, &Games.enqueue_cleanup(&1, :auto))`
- `lib/rule_maven/readiness.ex` line ~371: `Games.enqueue_cleanup(doc, :auto)`

- [ ] **Step 3: Remove the picker and `clean_level` plumbing from form.ex**

In `lib/rule_maven_web/live/game_live/form.ex`:

1. Line ~81: delete `clean_level: restore_clean_level(socket),` from the assigns.
2. Lines ~545–550: delete the whole `handle_event("set_clean_level", ...)` clause.
3. Lines ~1812–1818: delete the `clean_level_atom/1` clauses and their comment block.
4. In `start_cleanup/3` (~1820) and `start_page_cleanup/3` (~1845): delete the `level = clean_level_atom(...)` lines and call `Games.enqueue_cleanup(Games.get_document!(sid), :auto, mode)` / `Games.enqueue_cleanup_page(Games.get_document!(sid), index, :auto)`.
5. Lines ~2468–2478: delete `restore_clean_level/1` and its comment.
6. Lines ~3336–3354: delete the strength-picker markup — the `<%!-- Cleanup strength ... --%>` comment, the `<div title="How hard to scrub...">...</div>` wrapper and its `:for={lvl <- ~w(light standard aggressive)}` button. Keep the surrounding `cleaning?` / `has_cleaned` / `cur_cleaned` assigns (still used by the Clean buttons).
7. Update the Clean-button `title`/tooltip text if it mentions the selected strength (search the section for the word "strength" / "level"); new copy: `"Cleans this page — strength auto-adjusts per page"`.

- [ ] **Step 4: Remove the JS localStorage hook**

In `priv/static/assets/js/app.js`:
- Line ~816: delete `clean_level: localStorage.getItem("rm:clean:level") || "",` from the connect params.
- Line ~829: delete the whole `window.addEventListener("phx:save_clean_level", ...)` block.

- [ ] **Step 5: Remove the `cleanup_critic` settings toggle**

In `lib/rule_maven_web/live/settings_live.ex` delete the four `cleanup_critic` touchpoints (assign ~112, params ~260, save ~336, checkbox markup ~1020–1035). Leave `Settings` rows in the DB alone (stale key is harmless — nothing reads it now).

- [ ] **Step 6: Compile and run the affected tests**

Run: `mix compile --warnings-as-errors 2>&1 | tee tmp/ui.log`
Expected: clean compile (any leftover reference to deleted functions shows here).

Run: `mix test test/rule_maven_web/prepare_render_test.exs test/rule_maven_web/form_unextracted_source_test.exs test/rule_maven/readiness_test.exs 2>&1 | tee -a tmp/ui.log`
Expected: PASS. Then `rm tmp/ui.log`.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/games.ex lib/rule_maven_web/live/game_live/form.ex lib/rule_maven_web/live/game_live/prepare.ex lib/rule_maven/readiness.ex lib/rule_maven_web/live/settings_live.ex priv/static/assets/js/app.js
git commit -m "feat: auto clean level everywhere; drop strength picker and critic toggle"
```

---

### Task 6: Full-suite verification

**Files:** none new.

- [ ] **Step 1: Run the full test suite once**

Run: `mix test 2>&1 | tee tmp/full.log`
Expected: 0 failures. If failures, fix and re-run only the failing files.

- [ ] **Step 2: Clean up**

```bash
rm -f tmp/full.log
```

- [ ] **Step 3: Commit any fixes**

```bash
git add -A && git commit -m "test: fixes from full-suite run for auto-clean loop" || true
```
