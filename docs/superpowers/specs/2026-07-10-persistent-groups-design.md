# Persistent Groups — Design

**Date:** 2026-07-10
**Status:** Approved, pending implementation plan

## Summary

Persistent groups let a real crew (game-night friends, family, roommates) share a
private space of rulebook Q&A. A group spans all games but its feed is scoped
per-game: on a given game's Q&A screen a member sees that group's questions for
that game, live-updating as anyone in the crew asks. A member's question can be
answered instantly from a groupmate's earlier question (shared private cache),
and group content never leaks into the global community pool.

This is distinct from two existing systems it is often confused with:

- `RuleMaven.InviteCodes` — system-wide **registration** gating, not groups.
- The **community answer pool** — the *global* trusted corpus
  (`visibility == "community"` / `pooled == true`). Groups deliberately do NOT
  auto-feed it.

## Decisions (locked during brainstorming)

| Question | Decision |
|---|---|
| Group scope | Spans all games; feed filtered per game. |
| Visibility model | Group is a walled middle tier. Group questions default to `private` + `group_id`; never auto-pooled to community. Explicit per-row "promote to community" remains. |
| Shared cache | Yes. A member's ask draws cache hits from the group's own rows *plus* community *plus* verified/pooled — group acts as an extended "self" for caching. |
| Membership roles | Owner → admin → member. |
| Invite | One reusable, revocable link. Soft member cap (~12), enforced atomically. |
| Feed surface | Group panel on the game Q&A screen (sub-bar toggle), riding the existing `game:#{id}` PubSub topic. |
| Attribution | Attributed (`Sam asked…`). |
| Active group | Sticky per-game active-group selector: `Just me` (default) or one of my groups. Ask attaches to exactly the selected group. |
| Leave / removed | Rows keep `group_id`; crew retains knowledge; asker keeps their own via `user_id`. |
| Group deleted | Rows keep `user_id`; `group_id` cleared; each asker keeps theirs as private. |

## Data model

Two new schemas + one column on the existing question table. The question table
(`questions_log`) is hot; the only change to it is a single nullable FK.

### `groups` — `RuleMaven.Groups.Group`

Table `"groups"`.

- `id`
- `name :string`
- `owner_id` — `belongs_to :owner, RuleMaven.Users.User`
- `invite_code :string` — unique. Generated like `InviteCode.generate_code/0`:
  `:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false)`.
- `invite_active :boolean, default: true`
- `member_cap :integer, default: 12`
- timestamps

`Phoenix.Param` impl encodes `id` via `RuleMaven.Hashid` (mirrors
`games/game.ex:69`), so URLs are `/groups/:token` with opaque tokens. Context
getter `get_group_by_token/1` / `get_group_by_token!/1` decodes.

### `group_memberships` — `RuleMaven.Groups.Membership`

Table `"group_memberships"`. Join row.

- `belongs_to :user, RuleMaven.Users.User`
- `belongs_to :group, RuleMaven.Groups.Group`
- `role :string, default: "member"` — `validate_inclusion(~w(owner admin member))`
- timestamps
- `unique_index [:user_id, :group_id]`
- partial `unique_index [:group_id] where role = 'owner'` — one owner per group.

### `questions_log` — new column

- `group_id :integer` nullable FK → `groups`. Added to `belongs_to` assocs and to
  the changeset cast list (`question_log.ex`). Index `[:group_id]` (partial,
  `where group_id is not null`).

## Visibility + shared-cache semantics

**Write path.** Asking with an active group sets `group_id: <grp>` and
`visibility: "private"` on the new `QuestionLog` row. Because visibility stays
`private`, the row is invisible to community browse/pool surfaces
(`community_questions/2`, the `visibility == "community"` filters) exactly as any
private row is today. No new `visibility` enum value — the existing binary
`private`/`community` is untouched, avoiding a wide migration across the many
pool queries that hard-code `q.visibility == "community"`.

**Group content never auto-enters the community pool.** This protects the
trusted corpus (the whole point of the pooling/critic/trust machinery). A member
may still explicitly promote a specific answer to community via the existing
`set_question_visibility/2` path; that is a deliberate, per-row act.

**Read / cache path.** Extend `find_pool_candidates/3` (`games.ex:2604`) with an
optional `active_group_id`. When present, the candidate `WHERE` widens to also
match rows where `q.group_id == ^active_group_id` (subject to the same
freshness/refused/needs_review/error guards), in addition to the existing
`q.pooled == true or (q.visibility == "community" and q.citation_valid == true)`.
Group rows are served like private cache hits (answer-text fast path). Net: a
member's ask can hit **group rows + community + verified/pooled**.

- Cache hits remain quota-exempt (existing rule).
- A genuine miss runs one fresh LLM call, charged to the **asker's** quota, and
  the resulting row is written with `group_id` set — becoming a future group
  cache hit for the crew.

**Non-members** never receive group rows: the widened branch only activates when
the asker is a verified member of `active_group_id` (guarded server-side, see
Authz).

## Membership, invite, authz

**Roles.**

- **owner** — rename group, delete group, regenerate/revoke invite code,
  promote/demote admins, remove any member. Exactly one owner per group.
- **admin** — remove members, regenerate/revoke code.
- **member** — ask in group context, view feed, leave.

**Invite.** One reusable, revocable invite link per group. Owner/admin can
regenerate `invite_code` (old link immediately invalid) and toggle
`invite_active`. Joining consumes the code atomically, mirroring
`InviteCodes.consume/1`: an insert of the membership row guarded by a
member-count check (or a conditional insert) so a leaked link cannot push the
group past `member_cap` under concurrent joins. Duplicate join is a no-op
(unique `[:user_id, :group_id]`).

**Authz.** All group events and queries authorize server-side:

- `Groups.member?(user, group)` — gates feed reads, cache widening, asking in a
  group.
- `Groups.role_at_least?(user, group, role)` — gates admin/owner actions.
- Group resolution is always by token via `get_group_by_token/2`-style scoped
  getters; raw ids never appear in URLs (per the no-ids rule). LiveView events
  that carry a group token re-authorize on the server, never trusting the client
  (per the IDOR rule).

## Feed + realtime UX

**Active-group selector.** In the game sub-bar, a selector sets the current ask
context: `Just me` (default) or one of the groups the user belongs to. Choice is
sticky per game, stashed in the `TableSession` snapshot (ephemeral ETS is fine —
it is pure UI state; durable data lives in the DB).

**Group panel.** A sub-bar toggle on the game Q&A screen opens a panel showing
the active group's questions **for this game**, attributed (`Sam asked…`),
newest first. This is a game-scoped slice of `recent_questions/3` (`games.ex:2412`)
with an added `group_id == ^active_group_id` branch in the `WHERE`.

**Live updates.** Reuse the existing `game:#{game_id}` topic that
`show.ex:202` already subscribes to. `ask_worker` already broadcasts
`{:ask_complete, %{question_log_id, ...}}` (`ask_worker.ex:659`); add `group_id`
to that payload. When the panel is open on a matching group, an `:ask_complete`
whose `group_id` matches appends the new row live. No new PubSub topic.

**Out of scope for v1:** out-of-app / push notification when not viewing the
game; a cross-game group hub page. Live updates are only while a member is
viewing that game's screen.

## Lifecycle / edge cases

- **Leave or removed from group:** the member's `questions_log` rows keep their
  `group_id`, so remaining members retain the shared knowledge; the departed
  member still sees their own rows via `user_id` in personal history.
- **Group deleted:** rows keep `user_id`; `group_id` is cleared (set null on
  delete); each asker keeps theirs as a private row. The `groups` and
  `group_memberships` rows are removed.
- **Multi-group:** an ask attaches to exactly the selected active group; no
  fan-out to other groups the user belongs to.
- **Moderation:** existing `needs_review` / `stale` / `mismatch_count` /
  `error_kind` flags on `questions_log` continue to work; a member can flag a bad
  group answer like any other row. Group rows excluded from a member's cache
  lookup under the same guards as pool candidates.

## Testing

Scope limited to files touched by this change (per the run-only-necessary-tests
rule).

- **Context (`RuleMaven.Groups`, `RuleMaven.Games`):**
  - join consumes atomically; concurrent joins cannot exceed `member_cap`.
  - role authz matrix (member cannot remove; admin cannot delete group; owner
    can everything).
  - `find_pool_candidates/3` returns group rows for a member and denies them to
    a non-member.
  - leave keeps `group_id`; group delete nulls `group_id` and preserves rows.
- **LiveView (game Q&A screen):**
  - active-group selector switches context and is sticky per game.
  - group panel live-appends on `:ask_complete` with a matching `group_id`.
  - a non-member cannot open a group by token (IDOR guard).

## Scope guard (YAGNI — deferred)

- Cross-game group hub / standalone group page.
- Out-of-app or push notifications.
- Per-invite single-use codes.
- Group-level shared quota pooling.
- Anonymous-within-group asking.
