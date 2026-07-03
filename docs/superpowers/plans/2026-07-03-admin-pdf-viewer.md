# Admin PDF Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins view a source's original uploaded/downloaded PDF from the Prepare page and the admin edit form, via a new admin-gated HTTP endpoint.

**Architecture:** Extend the existing `RuleMavenWeb.RulebookController` (which already serves the admin-only extracted-text HTML view) with a `pdf/2` action that streams the stored PDF inline. Add "View PDF" links on the Prepare page source preview and next to "View as HTML" in the admin edit form.

**Tech Stack:** Phoenix 1.7 controller + LiveView, ExUnit.

**Spec:** `docs/superpowers/specs/2026-07-03-admin-pdf-viewer-design.md`

## Global Constraints

- Rulebooks may be copyrighted: PDF must never enter `static_paths`; the only HTTP access is this admin-gated endpoint. Regular users see only source names.
- Auth failures return **404, not 403** — the route must not reveal which documents exist to non-admins.
- Never expose raw ids in URLs — use `RuleMaven.Hashid` tokens (existing project rule).
- Test runs: tee output to `./tmp/` log file; delete the log when done (existing project rule).

---

### Task 1: Admin-gated PDF endpoint

**Files:**
- Modify: `lib/rule_maven_web/controllers/rulebook_controller.ex`
- Modify: `lib/rule_maven_web/router.ex` (next to the existing `get "/rulebooks/:id/html"` route, ~line 45)
- Test: `test/rule_maven_web/controllers/rulebook_controller_test.exs` (new file)

**Interfaces:**
- Consumes: `RuleMaven.Games.get_document/1`, `RuleMaven.Hashid.decode/1`, `RuleMaven.Users.can?/2` (all existing).
- Produces: `GET /rulebooks/:id/pdf` — 200 `application/pdf` (inline) for admins when the file exists; 404 otherwise. Tasks 2 and 3 link to this route via `~p"/rulebooks/#{RuleMaven.Hashid.encode(source_id)}/pdf"`.

- [ ] **Step 1: Write the failing tests**

Create `test/rule_maven_web/controllers/rulebook_controller_test.exs`:

```elixir
defmodule RuleMavenWeb.RulebookControllerTest do
  @moduledoc """
  Covers the admin-gated PDF endpoint. Rulebooks may be copyrighted, so the
  PDF is only reachable by admins, and every failure mode is a 404 (never a
  403) so the route doesn't reveal which documents exist.
  """

  use RuleMavenWeb.ConnCase, async: true
  import RuleMaven.GamesFixtures

  alias RuleMaven.Hashid

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user!(prefix, role \\ "user") do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  # Writes a real PDF file under priv/static so send_file has something to
  # serve; removed on exit. The relative path is unique per test run.
  defp create_pdf_doc!(game) do
    rel_path = "uploads/rulebooks/test_#{System.unique_integer([:positive])}.pdf"
    abs_path = Application.app_dir(:rule_maven, "priv/static/#{rel_path}")
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, "%PDF-1.4 fake test pdf")
    on_exit(fn -> File.rm(abs_path) end)

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: rel_path,
        pages: []
      })

    doc
  end

  setup %{conn: conn} do
    game = game_fixture(%{name: "PDF Test Game", bgg_id: 91_001})
    %{conn: conn, game: game}
  end

  test "admin gets the PDF inline", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin", "admin")
    doc = create_pdf_doc!(game)

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "inline"
    assert conn.resp_body =~ "%PDF-1.4"
  end

  test "non-admin gets 404", %{conn: conn, game: game} do
    user = create_user!("pdf_regular")
    doc = create_pdf_doc!(game)

    conn = conn |> login(user) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "anonymous gets 404", %{conn: conn, game: game} do
    doc = create_pdf_doc!(game)

    conn = get(conn, ~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "document without a pdf_path 404s for admins", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin_nopath", "admin")

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "No PDF",
        pages: []
      })

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end

  test "pdf_path pointing at a missing file 404s for admins", %{conn: conn, game: game} do
    admin = create_user!("pdf_admin_gone", "admin")

    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Gone PDF",
        pdf_path: "uploads/rulebooks/does_not_exist_#{System.unique_integer([:positive])}.pdf",
        pages: []
      })

    conn = conn |> login(admin) |> get(~p"/rulebooks/#{Hashid.encode(doc.id)}/pdf")

    assert conn.status == 404
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/rule_maven_web/controllers/rulebook_controller_test.exs 2>&1 | tee tmp/pdf_ctrl_test.log`
Expected: FAIL — router raises no route / `Phoenix.Router.NoRouteError` for `/rulebooks/:id/pdf` (verified route `~p` sigil fails to compile until the route exists; that compile error is the failure signal).

- [ ] **Step 3: Add route and controller action**

In `lib/rule_maven_web/router.ex`, directly under the existing HTML route:

```elixir
    # Extracted-text HTML view, admin-gated (rulebooks may be copyrighted; the
    # original PDF is never served over HTTP).
    get "/rulebooks/:id/html", RulebookController, :html
    # Original PDF, same admin gate — rendered inline in the browser's viewer.
    get "/rulebooks/:id/pdf", RulebookController, :pdf
```

In `lib/rule_maven_web/controllers/rulebook_controller.ex`, add below `html/2` (and update the `@moduledoc` first sentence to "Serves the extracted-text HTML view and the original PDF of a rulebook to admins only."):

```elixir
  def pdf(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with true <- user && Users.can?(user, :admin),
         {:ok, doc_id} <- RuleMaven.Hashid.decode(id),
         %Games.Document{pdf_path: pdf_path} when is_binary(pdf_path) <-
           Games.get_document(doc_id),
         full_path = Application.app_dir(:rule_maven, "priv/static/#{pdf_path}"),
         true <- File.exists?(full_path) do
      conn
      |> put_resp_content_type("application/pdf")
      |> put_resp_header("content-disposition", "inline")
      |> send_file(200, full_path)
    else
      # 404 (not 403) so the route doesn't reveal which documents exist to
      # non-admins.
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven_web/controllers/rulebook_controller_test.exs 2>&1 | tee tmp/pdf_ctrl_test.log`
Expected: 5 tests, 0 failures. Then `rm tmp/pdf_ctrl_test.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/controllers/rulebook_controller.ex lib/rule_maven_web/router.ex test/rule_maven_web/controllers/rulebook_controller_test.exs
git commit -m "feat: admin-gated PDF endpoint for rulebook sources"
```

---

### Task 2: "View PDF" link on Prepare page

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex` (the `:source` branch of `defp preview_body`, ~line 877)
- Test: `test/rule_maven_web/prepare_render_test.exs`

**Interfaces:**
- Consumes: `GET /rulebooks/:id/pdf` from Task 1. The `:source` preview receives full `Games.Document` structs (assigned as `source: docs` in `build_previews/2`), so each `d` has `d.id` and `d.pdf_path`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

Add to `test/rule_maven_web/prepare_render_test.exs` (the existing `with_doc/1` helper already sets `pdf_path: "uploads/rulebooks/x.pdf"`):

```elixir
  test "source preview links to the admin PDF view", %{conn: conn} do
    admin = admin!("prep_pdf_admin")
    game = game_fixture(%{name: "Prep PDF Game", bgg_id: 7789})
    doc = with_doc(game)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "View PDF"
    assert html =~ "/rulebooks/#{RuleMaven.Hashid.encode(doc.id)}/pdf"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/prepare_render_test.exs 2>&1 | tee tmp/prep_pdf_test.log`
Expected: FAIL — `html =~ "View PDF"` assertion fails.

- [ ] **Step 3: Add the link**

In `lib/rule_maven_web/live/game_live/prepare.ex`, `preview_body/1` `:source` branch, add the link inside the existing `<li>`:

```heex
        <% :source -> %>
          <ul style="margin:0;padding-left:1.1rem">
            <li :for={d <- @preview}>
              {d.label || "Untitled"}
              <span style="color:var(--text-muted)">· {d.page_count || length(d.pages)} pages</span>
              <.link
                :if={is_binary(d.pdf_path)}
                href={~p"/rulebooks/#{RuleMaven.Hashid.encode(d.id)}/pdf"}
                target="_blank"
                style="margin-left:0.4rem;font-size:0.75rem"
              >View PDF</.link>
            </li>
          </ul>
```

(Only the `<.link>` element is new; keep the surrounding markup as-is.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven_web/prepare_render_test.exs 2>&1 | tee tmp/prep_pdf_test.log`
Expected: all tests pass, 0 failures. Then `rm tmp/prep_pdf_test.log`.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/game_live/prepare.ex test/rule_maven_web/prepare_render_test.exs
git commit -m "feat: View PDF link on prepare page source preview"
```

---

### Task 3: "View PDF" link on admin edit form

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/form.ex` (~line 3392, the `entry[:source_id] && entry[:html_path]` block next to "View as HTML"; also delete the now-stale "No raw-PDF link" HEEx comment directly above it)
- Test: `test/rule_maven_web/form_pdf_link_test.exs` (new file)

**Interfaces:**
- Consumes: `GET /rulebooks/:id/pdf` from Task 1. Source entries already carry `pdf_path` and `source_id` (built by `source_entry/2`, form.ex ~line 1996).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/form_pdf_link_test.exs`:

```elixir
defmodule RuleMavenWeb.FormPdfLinkTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp admin!(name) do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    admin
  end

  defp with_pdf_doc(game) do
    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        pages: []
      })

    doc
  end

  test "edit form shows View PDF link for sources with a stored PDF", %{conn: conn} do
    admin = admin!("form_pdf_admin")
    game = game_fixture(%{name: "Form PDF Game", bgg_id: 7790})
    doc = with_pdf_doc(game)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    assert html =~ "View PDF"
    assert html =~ "/rulebooks/#{RuleMaven.Hashid.encode(doc.id)}/pdf"
  end
end
```

Note: if the "manage" tab (where source entries render) isn't in the initial `live/2` HTML, drive the view to it first — check how `test/rule_maven_web/form_unextracted_source_test.exs` reaches source entries and copy that navigation.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/form_pdf_link_test.exs 2>&1 | tee tmp/form_pdf_test.log`
Expected: FAIL — `html =~ "View PDF"` assertion fails.

- [ ] **Step 3: Add the link**

In `lib/rule_maven_web/live/game_live/form.ex`, replace the stale comment and add the link. Current code (~line 3390):

```heex
                    <%!-- No raw-PDF link: rulebooks may be copyrighted, so we
                          don't offer the original file for download. The HTML is
                          our extracted text (admin view only). --%>
                    <%= if entry[:source_id] && entry[:html_path] do %>
```

Replace with:

```heex
                    <%!-- PDF + HTML are admin-view only: rulebooks may be
                          copyrighted, so nothing here is reachable by regular
                          users (the controller 404s non-admins). --%>
                    <%= if entry[:source_id] && entry[:pdf_path] do %>
                      <.link
                        href={~p"/rulebooks/#{RuleMaven.Hashid.encode(entry.source_id)}/pdf"}
                        target="_blank"
                        class="action-link"
                      >View PDF</.link>
                    <% end %>
                    <%= if entry[:source_id] && entry[:html_path] do %>
```

(The existing `entry[:html_path]` block stays unchanged below.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/rule_maven_web/form_pdf_link_test.exs test/rule_maven_web/form_unextracted_source_test.exs 2>&1 | tee tmp/form_pdf_test.log`
Expected: all tests pass, 0 failures. Then `rm tmp/form_pdf_test.log`.

- [ ] **Step 5: Run the full web test suite once**

Run: `mix test test/rule_maven_web 2>&1 | tee tmp/web_suite.log`
Expected: 0 failures. Then `rm tmp/web_suite.log`.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/game_live/form.ex test/rule_maven_web/form_pdf_link_test.exs
git commit -m "feat: View PDF link on admin edit form"
```
