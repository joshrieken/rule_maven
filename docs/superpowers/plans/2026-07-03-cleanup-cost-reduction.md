# Cleanup Cost Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut rulebook-cleanup LLM cost (dashboard estimate and real tokens) without lowering quality, per `docs/superpowers/specs/2026-07-03-cleanup-cost-reduction-design.md`.

**Architecture:** Three independent changes: (1) real per-model rates in `LLM.Pricing`; (2) lane-aware skip in `CleanupWorker` — vision-transcribed pages skip the cleanup LLM call, drift-sampled for safety; (3) `NO_CHANGES` sentinel in the cleanup prompt + `LLM.cleanup_page/4` so clean pages cost ~10 output tokens.

**Tech Stack:** Elixir/Phoenix, Oban worker, ExUnit with `:llm_mock` app-env mock.

## Global Constraints

- Prompts live in the editable Prompts registry defaults (`lib/rule_maven/prompts.ex`), never hardcoded at call sites.
- Cleanup quality ladder (CleanCheck → critic → retry) must not change for pages that do get cleaned.
- Admin-forced cleans (single-page `page_index` runs, explicit `light`/`standard`/`aggressive` levels) never skip.
- Test output tee'd to `./tmp/*.log`; delete logs when done.

---

### Task 1: Real pricing for models missing from the table

**Files:**
- Modify: `lib/rule_maven/llm/pricing.ex:13-24` (`@prices` list)
- Test: `test/rule_maven/llm_cost_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.LLM.Pricing.rate/1`, `cost/3` (existing).
- Produces: nothing new — same API, more table entries.

- [ ] **Step 1: Write the failing test** (append to existing describe/tests in `test/rule_maven/llm_cost_test.exs`)

```elixir
  test "models in production logs resolve to real rates, not the default" do
    alias RuleMaven.LLM.Pricing
    assert Pricing.rate("deepseek/deepseek-v4-flash") == {0.089, 0.18}
    assert Pricing.rate("openai/gpt-5-mini") == {0.25, 2.00}
    assert Pricing.rate("google/gemini-3.1-pro-preview") == {2.00, 12.00}
    # gpt-5-mini must not substring-match a future bare "gpt-5" entry wrongly;
    # order in the table handles specificity.
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/llm_cost_test.exs 2>&1 | tail -5`
Expected: FAIL — rates come back `{0.50, 1.50}` (default).

- [ ] **Step 3: Add entries to `@prices`** (order matters only for substring specificity; put `gemini-3.1-pro` before the `gemini-2.5` entries for readability, exact placement free)

```elixir
  @prices [
    {"deepseek-v4-flash", {0.089, 0.18}},
    {"gpt-5-mini", {0.25, 2.00}},
    {"gemini-3.1-pro", {2.00, 12.00}},
    {"gemini-2.5-flash", {0.30, 2.50}},
    # ...existing entries unchanged below...
  ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/llm_cost_test.exs 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm/pricing.ex test/rule_maven/llm_cost_test.exs
git commit -m "fix: real dashboard rates for deepseek-v4-flash, gpt-5-mini, gemini-3.1-pro"
```

---

### Task 2: NO_CHANGES sentinel

**Files:**
- Modify: `lib/rule_maven/prompts.ex:122` (`@cleanup_output` fragment)
- Modify: `lib/rule_maven/llm.ex:362-395` (`cleanup_page/4`)
- Test: `test/rule_maven/llm_cleanup_guard_test.exs`

**Interfaces:**
- Consumes: `LLM.cleanup_page(page_text, level, page_number, opts)` returning `{:ok, text, status}`.
- Produces: same contract; a model reply of exactly `NO_CHANGES` returns `{:ok, page_text, :cleaned}` (the raw input back). Downstream `CleanupWorker.attempt/4` and `clean_meta/3` already reclassify identical-text results to `:unchanged`, feeding CleanCheck's existing `:unchanged` branch — no worker change needed.

- [ ] **Step 1: Write the failing test** (append to `test/rule_maven/llm_cleanup_guard_test.exs`)

```elixir
  test "NO_CHANGES sentinel returns the raw page as cleaned output" do
    mock("NO_CHANGES")
    assert {:ok, @raw, :cleaned} = LLM.cleanup_page(@raw, :light)
  end

  test "NO_CHANGES with surrounding whitespace still counts" do
    mock("  NO_CHANGES\n")
    assert {:ok, @raw, :cleaned} = LLM.cleanup_page(@raw, :light, nil, soft_guard: true)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/llm_cleanup_guard_test.exs 2>&1 | tail -5`
Expected: FAIL — "NO_CHANGES" is shorter than the floor → `{:ok, @raw, :kept_raw}` (hard guard) / `:guard_fired` (soft), not `:cleaned` with raw text.

- [ ] **Step 3: Implement.** In `lib/rule_maven/llm.ex` `cleanup_page/4`, add a sentinel branch at the TOP of the `cond` (before the empty/floor checks):

```elixir
          cond do
            trimmed == "NO_CHANGES" -> {:ok, page_text, :cleaned}
            trimmed == "" -> {:ok, page_text, :kept_raw}
            String.length(trimmed) >= min_keep -> {:ok, cleaned, :cleaned}
            opts[:soft_guard] -> {:ok, cleaned, :guard_fired}
            true -> {:ok, page_text, :kept_raw}
          end
```

In `lib/rule_maven/prompts.ex`, extend the shared output fragment:

```elixir
  @cleanup_output "Output ONLY the cleaned text, with no commentary and no code fences. If the text needs no repairs at all, output exactly NO_CHANGES instead of repeating the text."
```

(The fragment is inlined into each level's registry default; DB overrides in prod must be refreshed on deploy — note it in the commit body.)

- [ ] **Step 4: Run tests**

Run: `mix test test/rule_maven/llm_cleanup_guard_test.exs test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tail -5`
Expected: PASS (worker tests confirm no downstream breakage).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/llm.ex lib/rule_maven/prompts.ex test/rule_maven/llm_cleanup_guard_test.exs
git commit -m "feat: NO_CHANGES cleanup sentinel — clean pages stop echoing full text

DEPLOY: refresh any prod Prompts-registry override of cleanup_* templates."
```

---

### Task 3: Lane-aware skip with drift sampling

**Files:**
- Modify: `lib/rule_maven/workers/cleanup_worker.ex` (`clean_one/4` → `clean_one/5`, new `skippable_page?/3`, new reduce clause, stats, summary)
- Test: `test/rule_maven/workers/cleanup_worker_test.exs`

**Interfaces:**
- Consumes: `page.lane` / `page.confidence` (Document.Page embed, set by extraction), `RuleMaven.Extract.Calibrate.should_sample?/1`, `RuleMaven.Settings.get/1`.
- Produces: `CleanupWorker.skippable_page?(page, level, forced?)` → boolean (public, unit-tested). `clean_one` may return `:skipped` (new) alongside `{:ok, cleaned, meta}` / `:failed`.

- [ ] **Step 1: Write the failing tests** (append to `test/rule_maven/workers/cleanup_worker_test.exs`; follow the file's existing fixture style for building pages — a plain map/struct with `lane`, `confidence` fields)

```elixir
  describe "skippable_page?/3" do
    alias RuleMaven.Workers.CleanupWorker

    defp page(attrs), do: Map.merge(%{lane: "ensemble", confidence: 0.8}, attrs)

    test "vision-lane, confident page is skippable at auto level" do
      assert CleanupWorker.skippable_page?(page(%{lane: "ensemble"}), :auto, false)
      assert CleanupWorker.skippable_page?(page(%{lane: "vision"}), :auto, false)
    end

    test "text_layer and ocr lanes are never skipped" do
      refute CleanupWorker.skippable_page?(page(%{lane: "text_layer"}), :auto, false)
      refute CleanupWorker.skippable_page?(page(%{lane: "ocr"}), :auto, false)
    end

    test "low confidence disqualifies the skip" do
      refute CleanupWorker.skippable_page?(page(%{confidence: 0.5}), :auto, false)
      refute CleanupWorker.skippable_page?(page(%{confidence: nil}), :auto, false)
    end

    test "explicit levels and forced single-page runs always clean" do
      refute CleanupWorker.skippable_page?(page(%{}), :standard, false)
      refute CleanupWorker.skippable_page?(page(%{}), :aggressive, false)
      refute CleanupWorker.skippable_page?(page(%{}), :light, false)
      refute CleanupWorker.skippable_page?(page(%{}), :auto, true)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tail -5`
Expected: FAIL — `skippable_page?/3` undefined.

- [ ] **Step 3: Implement in `cleanup_worker.ex`**

Public decision function (near `clean_one`):

```elixir
  # Lanes whose text was produced by a vision-model transcription — already
  # LLM-shaped output, so a cleanup pass is a near-guaranteed no-op. Measured
  # on DungeonQuest post-column-fix: 7/12 pages "no changes", all vision-lane.
  @skip_lanes ~w(ensemble vision)
  # Same review threshold as Games.page_needs_review?/1 — below it the page is
  # already flagged for humans, so let cleanup have a look too.
  @skip_min_confidence 0.6

  @doc """
  Should this page skip the cleanup LLM call entirely? True only for auto-level
  bulk runs on confident vision-lane pages (their text already came out of a
  model — cleaning it again is paying to hear "no changes"). Forced runs
  (single-page re-clean) and explicit levels always clean. A drift sample of
  skippable pages is still cleaned by the caller to keep verifying this rule.
  """
  def skippable_page?(page, level, forced?) do
    not forced? and level == :auto and
      page.lane in @skip_lanes and
      is_number(page.confidence) and page.confidence >= @skip_min_confidence
  end
```

Thread `forced?` through and gate in `clean_one` (signature change; both call sites in this file):

```elixir
        fn page -> {page.index, clean_one(page, level, mode, game_id, is_integer(page_index))} end
```

```elixir
  defp clean_one(page, level, mode, game_id, forced?) do
    if skippable_page?(page, level, forced?) and not Calibrate.should_sample?(skip_sample_rate()) do
      :skipped
    else
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
  end
```

Aliases: add `RuleMaven.Extract.Calibrate` and `RuleMaven.Settings` to the alias lines. Sample-rate helper:

```elixir
  # Fraction of skippable pages that get cleaned anyway, so "vision lane =
  # already clean" keeps being verified. Admin-tunable like the extract drift
  # rate; 0.0 disables sampling, 1.0 disables skipping.
  defp skip_sample_rate do
    case Float.parse(Settings.get("cleanup_skip_sample_rate") || "") do
      {r, _} when r >= 0.0 and r <= 1.0 -> r
      _ -> 0.1
    end
  end
```

New reduce clause (insert between the `{:ok, cleaned, meta}` clause and the `:failed` clause; skipped pages advance the durable counter and broadcast progress with `nil` cleaned — `put_page_cleaned` in form.ex tolerates nil, effective text falls back to raw):

```elixir
        {:ok, {index, :skipped}}, acc ->
          done = min(acc.done + 1, total)
          Games.set_cleaning_done(doc_id, done)

          Jobs.event(
            run,
            "info",
            "Page #{index + 1} — skipped (vision-transcribed, already clean) · #{done}/#{total} done"
          )

          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            topic,
            {:page_cleaned, doc_id, index, nil, done, total}
          )

          acc |> Map.put(:done, done) |> Map.update(:skipped, 1, &(&1 + 1))
```

Stats init gains `skipped: 0`; summary notes gain the count (in `finish_summary/3` notes list):

```elixir
        Map.get(stats, :skipped, 0) > 0 && "#{stats.skipped} skipped (vision lane)",
```

- [ ] **Step 4: Integration test — skip actually avoids the LLM call.** Append (mirror the file's existing perform-style tests; the `:llm_mock` fn raises if called, proving no LLM traffic):

```elixir
  test "auto run skips confident vision-lane pages without calling the LLM" do
    Application.put_env(:rule_maven, :llm_mock, fn _ -> raise "LLM should not be called" end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    # Force sampling off so the test is deterministic.
    RuleMaven.Settings.put("cleanup_skip_sample_rate", "0.0")

    doc = insert_doc_with_pages(lane: "ensemble", confidence: 0.9)   # use the file's existing doc fixture helper
    assert :ok = perform_job(RuleMaven.Workers.CleanupWorker, %{"document_id" => doc.id, "game_id" => doc.game_id})

    doc = RuleMaven.Games.get_document!(doc.id)
    assert Enum.all?(doc.pages, &is_nil(&1.cleaned))
  end
```

(Adapt fixture/`perform_job` names to what the file already uses — read its setup block first.)

- [ ] **Step 5: Run worker tests**

Run: `mix test test/rule_maven/workers/cleanup_worker_test.exs 2>&1 | tail -5`
Expected: PASS. Note: existing tests build pages via extraction fixtures whose lane may be `"ensemble"` — if any legacy test now skips instead of cleaning, set that fixture's lane to `"text_layer"` or `cleanup_skip_sample_rate` handling accordingly; the pre-existing behavior contract ("cleans every page") applies to text-layer pages.

- [ ] **Step 6: Full suite**

Run: `mix test 2>&1 | tee tmp/test_cleanup_cost.log | tail -4`
Expected: only the known pre-existing failure (`prepare_render_test.exs:30`). Then `rm tmp/test_cleanup_cost.log`.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/workers/cleanup_worker.ex test/rule_maven/workers/cleanup_worker_test.exs
git commit -m "feat: skip cleanup for vision-transcribed pages, drift-sampled

Vision-lane pages already came out of an LLM; cleaning them again was a
paid no-op (7/12 pages on DungeonQuest). Auto-level bulk runs now skip
them; 10% drift sample (cleanup_skip_sample_rate) keeps verifying the
assumption. Forced/single-page/explicit-level runs always clean."
```

---

## Self-review notes

- Spec §1 → Task 1; §3 → Task 2; §2 → Task 3 (ordered so the prompt/sentinel lands before skip reduces its traffic — independent anyway).
- Drift-sample "warn on real changes" from spec: covered implicitly — a sampled page runs the normal path; if it produces changes the normal `Cleaned page N` info line + defect warns fire. No extra warn event needed (YAGNI; job log already shows it).
- `skippable_page?/3` types: page is the `Document.Page` embed (fields `lane :: String.t | nil`, `confidence :: float | nil`); `level :: atom`; `forced? :: boolean`.
