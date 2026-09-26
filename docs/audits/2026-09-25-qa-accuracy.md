# Q&A accuracy audit — 2026-09-25

Scope: every stored answer for the 4 Ready games (43 answers; Ethnos has none).
Each answer checked against the rulebook text in the DB (read-only).

| Game | Answers | Correct | Partial | Incorrect | Refusals (correct / false) |
|---|---|---|---|---|---|
| Zombicide: Black Plague (327) | 16 | 7 | 5 | 4 | 0 / 0 |
| Catan (966) | 14 | 11 | 0 | 1 | 2 / 1 |
| Horrified: D&D (3556) | 13 | 5 | 4 | 0 | 3 / 0 |
| **Total** | **43** | **23** | **9** | **5** | **5 / 1** |

Citations: every quoted passage exists verbatim on its cited page, except one
paraphrase that changed the verb (#64). No wrong stamps under the current
render rules.

Status legend: `open` · `fix-shipped` (code done, data not yet re-run) · `done`

## Systemic problems (fix these first — they cause the per-answer failures)

| ID | Problem | Evidence | Status |
|---|---|---|---|
| S1 | **Scenario pages split from their heading.** A quest's continuation page reached the model unlabeled; rules were credited to other quests. | BP #55, #68 (Quest 0 rules on p.39, heading on p.38) | fix-shipped (c3d11525, 4b91fe7a); Black Plague re-chunked 2026-09-26 04:08 — #68 verified fixed (now #70); regenerate #55 |
| S2 | **Vision model names glyphs instead of copying them — and it rewrites rules.** Re-extracted Horrified p.4/8/10/11 at 450 dpi with the b25f7ddc prompt (2026-09-26): "icon" dropped but guesses remain. Verified against the PDF: p.10 Mimic "discard (blue 6+)" → "discard [sword]"; p.10 Displacer Beast "discard (red/yellow 7+)" → "[sword]"; p.11 Beholder "use (yellow 6+)" → "use [action]"; p.11 Red Dragon printed word "symbols" → "[frenzy]". | Horrified #38, #49 | open — (1) hand-fix those 4 lines; (2) code detector: bracketed name after a cost verb → low confidence/review; (3) A/B another vision model on p.10–11 |
| S3 | **Grafted qualifier skips the critic.** Quotes were verbatim, but the answer moved "at any time, for free" off a *discard* rule onto *moving* cards. No cheap trigger fired, so the grounding critic never ran. | BP #64 | fix-shipped — new `:grafted` suspicion trigger (fires on 1/38 stored answers: #64). Verify by regenerating #64: log should show `grounding_critic trigger=grafted` |
| S4 | **Stops at the first matching line.** The decisive rule two lines away in the same passage is missed. | Horrified #42, #43; BP #64–#66 (p.19 "freely reorganize" never cited) | open |
| S5 | **Same question, different answers.** Paraphrases get opposite leads/verdicts; nothing reconciles them. | BP #57 vs #63, #65 vs #66 | open |
| S6 | **False refusal on a covered rule.** Terrain→resource mapping is in short captions ("Forest ⏎ Produces Lumber"). | Catan #10 | open — row predates source_chunk_ids, can't confirm retrieval; re-ask to reproduce |
| S7 | **Garbled cleaned text in chunks.** Figure captions fused into definitions; articles/verbs dropped. | BP p.9, p.17, p.22 | open — review cleanup output on those pages |
| S8 | **Surface-literal answers.** Misses what the text clearly implies; accepts false premises. | Horrified #42, #46, #47 | open — prompt |
| S9 | **Arbitrary verdicts on open questions.** `illegal` on "what happens…" questions. | Horrified #42, BP #68 | mitigated at render (98d6a356: open/negative questions show 📖) |

## Per-answer problems

### Zombicide: Black Plague

| # | Question (short) | Result | Problem | Fix | Status |
|---|---|---|---|---|---|
| 55 | What do the different objective colors mean in Quest 0? | incorrect | "Not covered" — p.39 Quest 0 special rules never retrieved; cited Quest 4's copy of a boilerplate line | S1 → re-chunk, regenerate | fix-shipped |
| 68 → 70 | When does a green spawn point activate in Quest 0? | incorrect → **correct** | Was "Rulebook has no Quest 0". After re-chunk (2026-09-26 04:08) + regenerate: cites p.39 "The green Spawn Zone is inactive until the green Objective is taken." | S1 | done |
| 64 | How is a newly found item equipped? | incorrect | Invented "free at any time" from p.17 "discard… for free". Reorganize costs an Action (p.20), free only right after a Search (p.19) | S3, S4; regenerate | open |
| 66 | Choosing weapons before each Action | incorrect | Answers the "three hands" case instead; swapping from Backpack costs a Reorganize Action | S4, S5; regenerate | open |
| 65 | Swapping inventory each turn | partial | "Can't do it multiple times per turn" is wrong — can, one Action each | S4; regenerate | open |
| 57 | Ranged attack in own zone — downside | partial | Friendly Fire isn't own-zone specific; real downside is losing target choice + minimum Range; contradicts #63 | S5; regenerate | open |
| 63 | Attacking in own zone — downside | partial | Only covers Ranged; misses target priority, minimum Range, Melee has no Friendly Fire | S5; regenerate | open |
| 51 | Can I close a door | partial | Right "No", but "locked up" is not distinct from closing | minor | open |
| 56 | Ranged attack in same zone | correct, thin | Misses minimum Range 0 requirement (Long Bow can't) and target priority | minor | open |
| 50 | Cards drawn at setup | correct, evasive | Never says plainly: none drawn; each Survivor dealt ≥1 Starting Equipment | minor | open |

### Catan

| # | Question (short) | Result | Problem | Fix | Status |
|---|---|---|---|---|---|
| 10 | What each terrain hex produces | incorrect (false refusal) | Shows RULES SILENT; mapping on p.3, p.10, p.16 | S6; regenerate | open |
| 12 | Piece limits | correct, thin | Misses that upgrading returns the settlement to supply | minor | open |
| 13 | Setup placement | correct | Mentions cities at setup (none are placed) | minor | open |
| 28 | Wood vs lumber | correct | Says "wood is often called lumber" backwards — rulebook only says lumber | minor | open |
| 20, 21 | (joke probe questions) | correct refusals | Leftover test rows | delete probe rows | open |

### Horrified: Dungeons & Dragons

| # | Question (short) | Result | Problem | Fix | Status |
|---|---|---|---|---|---|
| 42 | Events moving Monsters on their mat | partial | Misses p.10 "Monster card Events do not affect [Mimic on its mat]"; accepts false plural premise | S4, S8; regenerate | open |
| 46 | Monster difficulty ranking | partial | Presents a recommendation as a ranking; all sections say COMPLEXITY: HIGH | S8; regenerate | open |
| 47 | How many Monsters | partial | Says no number recommended; both recommendations + setup example use two | S8; regenerate | open |
| 49 | Defeating the Mimic | partial | Guessed "Weapon" for an untranscribed "[sword icon]" cost | S2; re-extract p.10, regenerate | open |
| 38 | Advancing the Mimic | correct, thin | Same icon guess; omits "discard the drawn Item" | S2 | open |
| 35, 45 | Revealing lairs | correct, thin | Drops "ANY COLOR" and blank Lair tokens | minor | open |
