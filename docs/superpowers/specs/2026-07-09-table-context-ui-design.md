# Table-context strip + expansions tool

**Date:** 2026-07-09
**Status:** Draft — pending review

## Goal

Make the user's table setup — which expansions they play with, how many house
rules they have — visible on every game screen, and reachable from every game
screen. Today the setup is persisted (`expansion_selections`) but effectively
invisible: the only place to see or change it is a toggle list buried in the
Q&A sidebar (`show.ex:3747`), and `Games.put_expansion_selection/3` has exactly
one call site.

This is the product wedge. A stateless chatbot over `rules.pdf` cannot know you
play base + Oceania with two house rules. Rule Maven already does — and never
says so.

## Non-goals

- Answer-card stamping ("answered for: base + Oceania"). Later, if wanted.
- Shared / broadcast table state. That is the shared-table-session spec.
- Any change to how expansions affect answers. `question_logs.expansion_ids`
  and `ExpansionDelta` already handle that and are tested.
- No migration. No schema change.

## Scope of "table context"

Per user, per base game — the existing `ExpansionSelection` row plus that user's
`HouseRule` rows. Not an ephemeral "tonight's table". A future shared table
session layers on top, treating this as the host's setup that guests inherit.

## Components

### 1. `SubBar.table_context/1` (new)

Pure function component in `sub_bar.ex` (~360 LOC, room to grow). No state, no
queries.

```
attr :game, :map, required: true
attr :expansions, :list, default: []        # names, already filtered to selected
attr :house_rule_count, :integer, default: 0
attr :has_expansions?, :boolean, default: false   # game defines any at all
```

Renders one flex row beneath the game title, left-aligned, **at all widths**:

```
🎲 +Oceania +1        🏠 2
```

- 🎲 half taps to the new `:expansions` tool.
- 🏠 half taps to the existing `:house_rules` tool. No new code for that half.

### 2. `ToolHost.load_table_context/1` (new)

`ToolHost.mount_header/1` is already the single call site on every game screen,
so this is one insertion point, not five. Two queries, both on indexed columns:

- `Games.get_expansion_selection/2`
- `HouseRules.list_for_user/2`

Assigns `:table_context`. Recomputed on `toggle_expansion` and on any house-rule
mutation — both already trigger refreshes (`refresh_house_rules/1`,
`show.ex:1436`).

**Not** cached in the `TableSession` ETS snapshot. It is a two-query read on
mount; caching buys nothing and introduces a coherence bug of exactly the kind
this codebase has been bitten by before.

### 3. `:expansions` tool (new)

```elixir
%{id: :expansions, emoji: "🎲", label: "Expansions", group: :play}
```

The 🎲 half of the strip has nowhere to tap today — this is the honest cost of
the design, and the part that actually changes behaviour.

- Toggle markup moves out of `show.ex:3747` into the tool. `show.ex` (~3000 LOC)
  gets smaller.
- The `toggle_expansion` handler (`show.ex:626`) moves with it, and must sit
  beside the tool's other handlers per the sub-bar convention.
- Expansion selection becomes reachable from every game screen, not one sidebar.

### 4. Rulebooks dropdown: removed

The `sources-dropdown` `<details>` in `header_pills` (`sub_bar.ex:142`) is a
`hide-mobile` desktop-only duplicate. The More menu (`sub_bar.ex:322-334`)
already lists the same source names and gives admins the same HTML link.
Removing the dropdown costs regular users nothing.

**One affordance exists only there and must be relocated:** the `↻ Regen` button
(`regenerate_html`), admin-only, gated to `current == :show`. It moves into the
More menu beside each admin source label, keeping both guards
(`@is_admin and src.html_path`, `@current == :show`). Deleting the dropdown
without this would remove `regenerate_html` from the app entirely.

The `sources` attr then drops off `header_pills`. The More menu keeps its own.

The strip does **not** move into the freed right-hand slot. That region holds
`hide-mobile` shortcuts; on a 390px screen it is nearly empty on purpose. The
strip stays left, one layout, all widths.

## Edge cases

| State | Render |
|---|---|
| Base game only (explicit `[]`) | `🎲 Base game`, muted |
| No house rules | `🏠 Add` — faint affordance, not blank |
| Game defines no expansions | 🎲 half hidden entirely |
| Long expansion list | `+First +N`; full list in `title` / `aria-label` |

The empty states are the cold-start play: a new user with nothing configured
still learns, on every screen and without a tour, that these features exist.

## Layout risk

At 390px the strip must never wrap. `flex-wrap:nowrap` in this exact bar has
already once run pills off-screen, silently clipped by `main-content`'s
`overflow-x`. Mitigation: `min-width:0` plus `text-overflow:ellipsis` on the
expansion span, and a test asserting the strip's right edge stays inside a
390px viewport.

## Testing

- `sub_bar_test.exs`: base-only, one expansion, many-expansions-truncated,
  no-house-rules, game-without-expansions.
- 390px overflow assertion (the regression above).
- Integration: changing expansions from the new tool updates the strip on a
  *different* game screen — proves the ToolHost wiring, not just the component.
- Contrast check on muted variants. WCAG floors are test-enforced here, and
  `--text-muted` on `--bg-subtle` is exactly the pairing that fails.
- Admin: `↻ Regen` still reachable from the More menu on `:show`, still absent
  elsewhere and for non-admins.

## Verification before merge

The strip advertises that house rules modify answers. That claim rests on the
embedding match attaching the *right* house rule to the *right* answer, which
has been verified as code-with-tests but not observed in a browser against a
real game. Drive one game with three house rules and confirm the overlay
attaches sensibly before this ships. If the match is poor, the strip is still
correct — but the pitch built on it is not.

## Sequencing note

The strip advertises state; the tool makes it changeable. If only one ships,
ship the tool.
