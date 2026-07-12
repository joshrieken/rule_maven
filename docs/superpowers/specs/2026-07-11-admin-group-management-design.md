# Admin group management

## Problem

Site admins and super admins have no way to see or manage persistent groups
(crews). `RuleMaven.Groups` mutators are all gated on the actor's *role
within that group* (`role_at_least?/3`) — a site admin who isn't a member of
a group cannot rename it, remove a stuck member, force a transfer, or delete
it, even for abuse/support cases (dead crew, griefing owner, deletion
request).

## Scope

Any user with `Users.can?(user, :admin)` gets full control: view all groups,
search, and perform every mutation a group's own owner/admin could perform —
rename, invite toggle/regenerate, member cap, community-contribution toggle,
role changes, ownership transfer, member removal, group deletion. No
super-admin-only split; `:admin` is the single gate, consistent with how
`AdminLive.Moderation` already lets any admin act.

## Context changes (`RuleMaven.Groups`)

Each actor-gated mutator is split into a private `do_*` mechanics function
(unchanged locking/invariant/cascade logic) and two public callers:

- the existing actor-gated wrapper (`role_at_least?/3` check, unchanged
  behavior for group members)
- a new `admin_*` wrapper that calls the same `do_*` function directly, no
  membership or role check — the caller (LiveView) has already checked
  `Users.can?(:admin)`

Functions to split this way: `rename`, `set_invite_active`,
`set_member_cap`, `set_contribute`, `regenerate_code`, `set_role`,
`transfer_ownership`, `remove_member`, `delete_group`.

All invariants stay in the shared `do_*` code: single-owner uniqueness,
member-cap > 0, owner-can't-be-removed-directly, retroactive contribution
retraction, advisory-lock critical sections. The admin path bypasses only
"is this actor privileged *within this group*" — every other rule still
applies (e.g. `admin_remove_member` still refuses to remove an owner;
`admin_set_role` still refuses to touch/create an owner row; use
`admin_transfer_ownership` for that).

New read function: `list_all(search \\ nil)` — returns all groups
(optionally `ilike` filtered by name), each annotated with `member_count`
and `owner_username`, ordered by name.

## LiveViews

### `AdminLive.Groups` — `/admin/groups`

List/search page, modeled on `AdminLive.Users`. Table columns: name, owner,
member count, contribute (icon), invite active (icon), created date. Search
box filters by name (phx-change, debounced via `phx-debounce`). Row actions:
View (navigates to detail) and Delete (with `data-confirm`, calls
`Groups.admin_delete_group/1`, audit-logged, list reloads).

Gated `Users.can?(current_user, :admin)` in `mount/3`, redirect to `/` with
a flash otherwise (matches every other `AdminLive.*` page).

### `AdminLive.GroupShow` — `/admin/groups/:token`

Detail page. Resolves the group via `Groups.get_group_by_token/1` (no
membership check — that's the point). 404-equivalent (flash + redirect to
`/admin/groups`) for an unknown token.

UI is adapted from `GroupLive.Show`'s sections (invite link, members,
community sharing, rename, danger zone) but every action calls the
`admin_*` context function instead of the actor-gated one, and every
`:if={@role in [...]}` gate is removed — admin always sees every control
regardless of their own membership/role in the group. A banner at the top
reads "Admin view — you are not a member of this group" when the current
user has no membership row, so the page is unambiguous about what's
happening.

Member table reuses the same role-change/remove/transfer-ownership actions
as `GroupLive.Show`, wired to `admin_set_role/3`, `admin_remove_member/2`,
`admin_transfer_ownership/2`.

Delete redirects to `/admin/groups` (not `/groups`) on success.

### `AdminLive.Index`

Add a "Groups" card to the existing "Manage" section, linking to
`/admin/groups`.

## Audit logging

Every admin mutation logs through `RuleMaven.Audit.log/3` with
`target_type: "group"`, `target_id: group.id`, `target_label: group.name`,
and a `metadata` map describing the change — matching the existing pattern
in `AdminLive.Users` and `GroupLive.Show`'s error/flash conventions. Actions
logged: `group.rename`, `group.delete`, `group.remove_member`,
`group.transfer_ownership`, `group.set_role`, `group.set_contribute`,
`group.set_member_cap`, `group.toggle_invite`, `group.regenerate_code`.

## Routes

```
live "/admin/groups", AdminLive.Groups, :index
live "/admin/groups/:token", AdminLive.GroupShow, :show
```

Both inside the existing `live_session :admin` scope alongside every other
`AdminLive.*` route.

## Testing

- `RuleMaven.Groups` unit tests: each new `admin_*` function, exercised by a
  non-member site-admin actor, confirming the mutation succeeds and every
  existing invariant (owner protection, cap validation, retraction) still
  holds — mirroring the existing test coverage for the actor-gated
  counterparts.
- LiveView feature tests: non-admin redirected away from both new routes;
  admin can list/search/view/mutate a group they don't belong to; audit log
  rows are written.

## Out of scope

- Pagination on the groups list (matches `AdminLive.Users`/`AdminLive.Invites`
  today — revisit if the group count grows large).
- Bulk actions.
- Restricting any of this to super-admin-only (explicitly rejected — `:admin`
  is the single gate per this design).
