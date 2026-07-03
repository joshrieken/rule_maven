# Admin PDF Viewer (Prepare Page + Edit Form)

**Date:** 2026-07-03
**Status:** Approved

## Goal

Admins (game masters) need to view a source's original uploaded/downloaded PDF
while working on the Prepare page. Today the PDF is stored on disk but has no
HTTP access at all.

## Copyright constraint (unchanged)

Rulebooks may be copyrighted. The standing rule locks down *user-facing*
access: the PDF is never in `static_paths`, and regular users only ever see a
source's name. Admin-gated access is already established precedent — the
extracted-text HTML view (`GET /rulebooks/:id/html`) is served to admins by
`RuleMavenWeb.RulebookController`. This feature extends that same pattern to
the PDF. No user-facing exposure changes.

## Design

### Endpoint

Add `pdf/2` to the existing `RuleMavenWeb.RulebookController`:

- Route: `GET /rulebooks/:id/pdf` (same scope as the HTML route).
- Gate identical to `html/2`: `current_user` present and
  `Users.can?(user, :admin)`, Hashid-decoded id, document must have a binary
  `pdf_path`, file must exist on disk.
- Any failure returns **404, not 403**, so the route does not reveal which
  documents exist to non-admins.
- Serve with `send_file`, `content_type "application/pdf"`, and
  `Content-Disposition: inline` so the browser renders it in its native
  viewer instead of downloading.
- File is read from the filesystem via `Application.app_dir(:rule_maven,
  "priv/static/#{pdf_path}")` — the PDF stays out of `static_paths`.

### UI

Two placements, both already admin-gated surfaces:

1. **Prepare page** (`game_live/prepare.ex`): a "View PDF" link next to each
   source in the source list, shown only when the document has a `pdf_path`.
   Opens in a new tab (`target="_blank"`), browser's native PDF viewer.
2. **Admin edit form** (`game_live/form.ex`): same "View PDF" link beside the
   existing "View as HTML" link, same `pdf_path` presence check.

### Testing

Controller tests mirroring the existing HTML-view tests:

- Admin with a document that has a PDF on disk → 200, `application/pdf`
  content type.
- Non-admin user → 404.
- Anonymous → 404.
- Document without `pdf_path` or with a missing file → 404.

## Alternatives considered

- **Separate controller** — no benefit; `RulebookController` already owns
  admin-gated rulebook serving.
- **Embedded iframe/modal viewer** — more UI work, clunky on small screens;
  rejected in favor of new-tab native viewer.
