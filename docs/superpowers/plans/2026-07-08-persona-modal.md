# Persona Picker Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the persona ("Answer persona") dropdown with a centered, viewport-safe modal that both the composer and per-answer pickers open, enriched with descriptions, a voice sample line, a 🔥 Popular badge, a search filter, and a recently-used strip.

**Architecture:** A single `persona_modal/1` function component in `show.ex`, driven by a `persona_modal` LiveView assign (nil | routing context). Persona selection routes to the existing `set_voice` / `set_default_voice` events. A new `persona_events` table records selections and powers both popularity (top-N per game) and recently-used (per user), computed once when the modal opens.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto/Postgres, vanilla JS hook, hand-written CSS in `priv/static/assets/css/app.css` (served directly, no build step).

## Global Constraints

- User-facing term for the trait is **persona** (the code type is `voice`); keep that split.
- Buttons use the shared `btn-*` / `card-menu` classes; do not invent inline button styles.
- No raw usage numbers in the UI — popularity is a 🔥 badge only.
- Selection recording must be best-effort: never block or error a persona pick.
- Personas are logged-in only on this page (`socket.assigns.current_user` always set), but keep `user_id` nullable in the schema.
- `voice_id` strings: built-ins like `"neutral"`, `"court-case"`; game voices prefixed `"g:"` (`@game_prefix` in `RuleMaven.Voices`).
- Existing `game_voice.popularity_rank` is a generation-time rank — unrelated to this usage-based popularity. Do not reuse it for the badge.

---

### Task 1: `persona_events` table + schema + `record_event/3`

**Files:**
- Create: `priv/repo/migrations/20260708120000_create_persona_events.exs`
- Create: `lib/rule_maven/voices/persona_event.ex`
- Modify: `lib/rule_maven/voices.ex` (alias + `record_event/3`)
- Test: `test/rule_maven/voices_test.exs` (create if absent)

**Interfaces:**
- Produces: `RuleMaven.Voices.PersonaEvent` schema; `RuleMaven.Voices.record_event(user_id, game_id, voice_id)` → `:ok` (best-effort, always returns `:ok`).

- [ ] **Step 1: Migration**

```elixir
defmodule RuleMaven.Repo.Migrations.CreatePersonaEvents do
  use Ecto.Migration

  def change do
    create table(:persona_events) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :game_id, references(:games, on_delete: :delete_all), null: false
      # Voice/persona id as used in the picker: "neutral", "court-case", "g:slug".
      add :voice_id, :string, null: false
      timestamps(updated_at: false)
    end

    # Popularity: count by (game_id, voice_id). Recency: newest per user.
    create index(:persona_events, [:game_id, :voice_id])
    create index(:persona_events, [:user_id, :inserted_at])
  end
end
```

- [ ] **Step 2: Schema**

```elixir
defmodule RuleMaven.Voices.PersonaEvent do
  @moduledoc "One persona (voice) selection, used for popularity + recently-used."
  use Ecto.Schema
  import Ecto.Changeset

  schema "persona_events" do
    field :user_id, :id
    field :game_id, :id
    field :voice_id, :string
    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :game_id, :voice_id])
    |> validate_required([:game_id, :voice_id])
  end
end
```

- [ ] **Step 3: Failing test**

```elixir
# test/rule_maven/voices_test.exs
defmodule RuleMaven.VoicesTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Voices
  alias RuleMaven.Voices.PersonaEvent
  import RuleMaven.Repo, only: []

  describe "record_event/3" do
    test "inserts a persona event row" do
      game = RuleMaven.GamesFixtures.game_fixture()
      assert :ok = Voices.record_event(nil, game.id, "neutral")
      assert [%PersonaEvent{voice_id: "neutral", game_id: gid}] =
               RuleMaven.Repo.all(PersonaEvent)
      assert gid == game.id
    end

    test "returns :ok even on bad input (best-effort)" do
      assert :ok = Voices.record_event(nil, nil, nil)
    end
  end
end
```

> Note: confirm the fixture module name with `grep -rn "def game_fixture" test/support`. If games use a different fixture (e.g. `RuleMaven.GamesFixtures`), match it; otherwise insert a `%RuleMaven.Games.Game{}` directly.

- [ ] **Step 4: Run — expect fail**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: FAIL (`record_event/3` undefined).

- [ ] **Step 5: Implement**

In `lib/rule_maven/voices.ex`, extend the alias and add the function:

```elixir
# change existing alias line:
alias RuleMaven.Voices.{AnswerVoice, GameVoice, PersonaEvent}

@doc """
Records a persona (voice) selection for popularity + recently-used stats.
Best-effort: never raises, never blocks a selection. Returns :ok always.
"""
def record_event(user_id, game_id, voice_id) do
  %PersonaEvent{}
  |> PersonaEvent.changeset(%{user_id: user_id, game_id: game_id, voice_id: voice_id})
  |> Repo.insert()
  |> case do
    {:ok, _} -> :ok
    {:error, cs} -> Logger.warning("persona_event insert failed: #{inspect(cs.errors)}"); :ok
  end
rescue
  e -> Logger.warning("persona_event insert crashed: #{inspect(e)}"); :ok
end
```

Ensure `require Logger` (or `import`) is present at the top of `voices.ex`; add `require Logger` if not.

- [ ] **Step 6: Run — expect pass**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260708120000_create_persona_events.exs lib/rule_maven/voices/persona_event.ex lib/rule_maven/voices.ex test/rule_maven/voices_test.exs
git commit -m "feat: persona_events table + record_event/3"
```

---

### Task 2: `popular_voice_ids/2` + `recent_voice_ids/3`

**Files:**
- Modify: `lib/rule_maven/voices.ex`
- Test: `test/rule_maven/voices_test.exs`

**Interfaces:**
- Consumes: `record_event/3`, `PersonaEvent` (Task 1).
- Produces:
  - `popular_voice_ids(game_id, limit \\ 3)` → `MapSet.t(String.t())` of the top voice_ids by count for that game (empty when no rows).
  - `recent_voice_ids(user_id, game_id, limit \\ 4)` → `[String.t()]`, distinct, most-recent-first, game-scoped (`[]` when `user_id` is nil or no history).

- [ ] **Step 1: Failing tests**

```elixir
describe "popular_voice_ids/2" do
  test "ranks voices by selection count, honoring the limit" do
    g = RuleMaven.GamesFixtures.game_fixture()
    for _ <- 1..3, do: Voices.record_event(nil, g.id, "neutral")
    for _ <- 1..2, do: Voices.record_event(nil, g.id, "court-case")
    Voices.record_event(nil, g.id, "gran")
    assert Voices.popular_voice_ids(g.id, 2) == MapSet.new(["neutral", "court-case"])
  end

  test "empty when no events" do
    g = RuleMaven.GamesFixtures.game_fixture()
    assert Voices.popular_voice_ids(g.id) == MapSet.new([])
  end
end

describe "recent_voice_ids/3" do
  test "returns distinct recent voices, newest first, scoped to user+game" do
    g = RuleMaven.GamesFixtures.game_fixture()
    u = RuleMaven.AccountsFixtures.user_fixture()
    Voices.record_event(u.id, g.id, "neutral")
    Voices.record_event(u.id, g.id, "court-case")
    Voices.record_event(u.id, g.id, "neutral")  # dedup, bumps recency
    assert Voices.recent_voice_ids(u.id, g.id, 4) == ["neutral", "court-case"]
  end

  test "empty for nil user" do
    g = RuleMaven.GamesFixtures.game_fixture()
    assert Voices.recent_voice_ids(nil, g.id) == []
  end
end
```

> Confirm the user fixture name via `grep -rn "def user_fixture" test/support`; adjust module if different.

- [ ] **Step 2: Run — expect fail**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: FAIL (functions undefined).

- [ ] **Step 3: Implement**

```elixir
@doc "MapSet of the top `limit` voice_ids by selection count for a game."
def popular_voice_ids(game_id, limit \\ 3) do
  from(e in PersonaEvent,
    where: e.game_id == ^game_id,
    group_by: e.voice_id,
    order_by: [desc: count(e.id)],
    limit: ^limit,
    select: e.voice_id
  )
  |> Repo.all()
  |> MapSet.new()
end

@doc "Distinct recent voice_ids for a user on a game, most-recent-first."
def recent_voice_ids(nil, _game_id, _limit), do: []

def recent_voice_ids(user_id, game_id, limit \\ 4) do
  from(e in PersonaEvent,
    where: e.user_id == ^user_id and e.game_id == ^game_id,
    group_by: e.voice_id,
    order_by: [desc: max(e.inserted_at)],
    limit: ^limit,
    select: e.voice_id
  )
  |> Repo.all()
end
```

> The `recent_voice_ids(nil, ...)` head must appear BEFORE the defaulted head, or the default-arg head will shadow it. Place the nil clause first and give the defaulted clause the `\\` default; Elixir generates the arity-2 wrapper from the defaulted head. To avoid a "default in multiple clauses" issue, define a private `do_recent/3` and have two public heads delegate, OR keep a single head with a guard `when is_integer(user_id)` returning the query and a separate `recent_voice_ids(nil, _, _)`. Use this exact shape:

```elixir
def recent_voice_ids(user_id, game_id, limit \\ 4)
def recent_voice_ids(nil, _game_id, _limit), do: []
def recent_voice_ids(user_id, game_id, limit) do
  # query as above
end
```

- [ ] **Step 4: Run — expect pass**

Run: `mix test test/rule_maven/voices_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/voices.ex test/rule_maven/voices_test.exs
git commit -m "feat: popular_voice_ids + recent_voice_ids queries"
```

---

### Task 3: Modal state, open/close handlers, event recording

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (mount assign, handlers)
- Test: `test/rule_maven_web/live/game_live/persona_modal_test.exs` (create)

**Interfaces:**
- Consumes: `Voices.record_event/3`, `popular_voice_ids/2`, `recent_voice_ids/3`.
- Produces: assigns `persona_modal` (`nil | %{target: :default | {:answer, integer}}`), `persona_popular` (MapSet), `persona_recent` (list); events `open_persona_modal`, `close_persona_modal`.

- [ ] **Step 1: Failing LiveView test**

```elixir
defmodule RuleMavenWeb.GameLive.PersonaModalTest do
  use RuleMavenWeb.ConnCase
  import Phoenix.LiveViewTest
  alias RuleMaven.Repo
  alias RuleMaven.Voices.PersonaEvent

  setup :register_and_log_in_user   # match this repo's ConnCase helper name

  test "opening from composer sets modal target and picking records an event", %{conn: conn} do
    game = RuleMaven.GamesFixtures.playable_game_fixture()  # a game with sources so the composer renders
    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")

    lv |> element("[phx-click=open_persona_modal][phx-value-target=default]") |> render_click()
    assert has_element?(lv, "#persona-modal")

    lv |> element("#persona-modal [phx-value-voice=neutral]") |> render_click()
    refute has_element?(lv, "#persona-modal")
    assert Repo.aggregate(PersonaEvent, :count) == 1
  end
end
```

> Adjust: the log-in helper name (`grep -rn "def register_and_log_in_user\|log_in_user" test/support`), and the game fixture that yields a Ready game with a source so the composer row renders. If no such fixture exists, build one inline (insert Game with `playable: true` + a document/source).

- [ ] **Step 2: Run — expect fail**

Run: `mix test test/rule_maven_web/live/game_live/persona_modal_test.exs`
Expected: FAIL (no `#persona-modal`, handler missing).

- [ ] **Step 3: Add mount assign**

In `mount/…` initial `assign(socket, …)` (near the top assign block, ~line 16), add:

```elixir
persona_modal: nil,
persona_popular: MapSet.new(),
persona_recent: [],
```

- [ ] **Step 4: Add handlers**

Place near the `set_voice` handlers (after line 850):

```elixir
def handle_event("open_persona_modal", params, socket) do
  target =
    case params do
      %{"target" => "answer", "msg-id" => id} -> {:answer, String.to_integer(id)}
      _ -> :default
    end

  game = socket.assigns.game
  uid = socket.assigns.current_user && socket.assigns.current_user.id

  {:noreply,
   assign(socket,
     persona_modal: %{target: target},
     persona_popular: RuleMaven.Voices.popular_voice_ids(game.id),
     persona_recent: RuleMaven.Voices.recent_voice_ids(uid, game.id)
   )}
end

def handle_event("close_persona_modal", _params, socket) do
  {:noreply, assign(socket, persona_modal: nil)}
end
```

- [ ] **Step 5: Record + close inside the selection handlers**

Modify `set_voice` and `set_default_voice` (lines 820–843) so that, on a valid voice, they also record the event and close the modal. Replace the two handler bodies with:

```elixir
def handle_event("set_voice", %{"voice" => voice}, socket) do
  if not RuleMaven.Voices.valid?(voice, socket.assigns.game) do
    {:noreply, socket}
  else
    record_persona_pick(socket, voice)

    {:noreply,
     socket
     |> assign(voice_sel: %{}, persona_modal: nil)
     |> apply_default_voice(voice)
     |> push_event("save_default_voice", %{voice: voice})}
  end
end

def handle_event("set_default_voice", %{"voice" => voice}, socket) do
  if RuleMaven.Voices.valid?(voice, socket.assigns.game) do
    record_persona_pick(socket, voice)

    {:noreply,
     socket
     |> assign(persona_modal: nil)
     |> apply_default_voice(voice)
     |> push_event("save_default_voice", %{voice: voice})}
  else
    {:noreply, socket}
  end
end

# Best-effort selection stat; must not affect the reply.
defp record_persona_pick(socket, voice) do
  uid = socket.assigns.current_user && socket.assigns.current_user.id
  RuleMaven.Voices.record_event(uid, socket.assigns.game.id, voice)
end
```

- [ ] **Step 6: Run — expect fail on missing modal markup**

Run: `mix test test/rule_maven_web/live/game_live/persona_modal_test.exs`
Expected: still FAIL — `#persona-modal` isn't rendered yet (added in Task 4). This is expected; the handler code compiles. Verify compile: `mix compile` succeeds.

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex test/rule_maven_web/live/game_live/persona_modal_test.exs
git commit -m "feat: persona modal state + handlers + selection recording"
```

---

### Task 4: Modal + card components, replace pills, CSS

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (replace `voice_menu`/`voice_menu_item`; add `persona_modal/1`, `persona_card/1`; swap the two `<details>` pills for buttons; render the modal once)
- Modify: `priv/static/assets/css/app.css` (modal styles)
- Test: reuse `persona_modal_test.exs` from Task 3 (should now pass).

**Interfaces:**
- Consumes: `persona_modal`, `persona_popular`, `persona_recent` assigns; `@voices`, `@default_voice`, `@voice_sel`, `@game`.
- Produces: `#persona-modal` DOM with `.persona-card` rows carrying `phx-value-voice` and `data-search`.

- [ ] **Step 1: Replace the composer pill (`<details>` at ~line 4530)** with a button:

```heex
<button
  type="button"
  phx-click="open_persona_modal"
  phx-value-target="default"
  data-tour="voices"
  style="font-size:0.68rem;color:var(--text);font-weight:600;border:1px solid var(--border);border-radius:999px;padding:0.15rem 0.55rem;background:var(--bg-surface);cursor:pointer;display:inline-flex;align-items:center;gap:0.25rem"
>
  <span aria-hidden="true">{cur_default.emoji}</span>
  <span>{cur_default.label}</span>
  <span style="opacity:0.6">▾</span>
</button>
```

(Keep the surrounding `<div … "Answer persona">` label wrapper; only the `<details>…</details>` becomes this button. Move the `data-tour="voices"` from the old wrapper onto the button.)

- [ ] **Step 2: Replace the per-answer switcher (`<details>` at ~line 3533)** with a button that preserves the disabled/speaking styling:

```heex
<button
  type="button"
  phx-click={show_voice && "open_persona_modal"}
  phx-value-target="answer"
  phx-value-msg-id={msg[:id]}
  disabled={!show_voice}
  aria-disabled={!show_voice}
  style={"font-size:0.65rem;font-weight:600;border-radius:999px;padding:0.12rem 0.5rem;display:inline-flex;align-items:center;gap:0.2rem;cursor:pointer;#{if !show_voice, do: "opacity:0.55;pointer-events:none;"}#{if speaking, do: "border:1px solid color-mix(in srgb,var(--accent) 55%,transparent);background:color-mix(in srgb,var(--accent) 12%,transparent);color:var(--text)", else: "border:1px solid var(--border);background:var(--bg-surface);color:var(--text-muted)"}"}
  title="Answer persona — your pick applies to every answer and is remembered"
>
  <span :if={String.starts_with?(cur_voice, "g:")} aria-hidden="true" style="color:var(--accent)">✦</span>
  <span aria-hidden="true">{cur.emoji}</span>
  <span>{if speaking, do: "#{cur.label} speaking", else: "#{cur.label} persona"}</span>
  <span style="opacity:0.6">▾</span>
</button>
```

- [ ] **Step 3: Render the modal once**, just before the closing of the `.chat-layout` container (after the composer block, near the end of the main `render/1`):

```heex
<.persona_modal
  :if={@persona_modal}
  target={@persona_modal.target}
  voices={@voices}
  game={@game}
  default_voice={@default_voice}
  current={persona_modal_current(@persona_modal.target, @voice_sel, @default_voice)}
  popular={@persona_popular}
  recent={@persona_recent}
/>
```

Add the small helper near the other private helpers:

```elixir
# Which voice should render as "selected" in the modal for a given target.
defp persona_modal_current(:default, _voice_sel, default_voice), do: default_voice
defp persona_modal_current({:answer, msg_id}, voice_sel, default_voice),
  do: Map.get(voice_sel, msg_id, default_voice)
```

- [ ] **Step 4: Add the components** (replace `voice_menu/1` and `voice_menu_item/1` entirely):

```elixir
attr :target, :any, required: true
attr :voices, :list, required: true
attr :game, :map, required: true
attr :default_voice, :string, required: true
attr :current, :string, required: true
attr :popular, :any, required: true    # MapSet of voice_ids
attr :recent, :list, required: true    # ordered voice_ids

defp persona_modal(assigns) do
  {game_voices, builtin} = Enum.split_with(assigns.voices, &String.starts_with?(&1.id, "g:"))
  {plain, alt} = Enum.split_with(builtin, &(&1.id == "neutral"))
  by_id = Map.new(assigns.voices, &{&1.id, &1})
  recent = Enum.map(assigns.recent, &Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  event = case assigns.target do
    :default -> "set_default_voice"
    {:answer, _} -> "set_voice"
  end

  assigns =
    assign(assigns,
      plain: plain, game_voices: game_voices, alt: alt, recent_voices: recent, event: event)

  ~H"""
  <div
    id="persona-modal"
    class="persona-modal-backdrop"
    phx-click="close_persona_modal"
    phx-window-keydown="close_persona_modal"
    phx-key="Escape"
  >
    <div class="persona-modal" phx-click-away="close_persona_modal" phx-hook="PersonaFilter" id="persona-modal-panel">
      <div class="persona-modal__head">
        <span class="persona-modal__title">Answer persona</span>
        <button type="button" class="btn-icon" phx-click="close_persona_modal" aria-label="Close">✕</button>
      </div>
      <input
        type="text"
        class="persona-modal__search"
        placeholder="Search personas…"
        data-persona-filter-input
        autocomplete="off"
        phx-update="ignore"
        id="persona-search"
      />
      <div class="persona-modal__scroll">
        <div :if={@recent_voices != []} class="persona-modal__section">Recently used</div>
        <.persona_card
          :for={v <- @recent_voices}
          voice={v} game={@game} event={@event}
          selected={@current == v.id} is_default={@default_voice == v.id}
          popular={MapSet.member?(@popular, v.id)}
        />

        <.persona_card
          :for={v <- @plain}
          voice={v} game={@game} event={@event}
          selected={@current == v.id} is_default={@default_voice == v.id}
          popular={MapSet.member?(@popular, v.id)}
        />

        <div :if={@game_voices != []} class="persona-modal__section persona-modal__section--game">
          ✦ {@game.name}
        </div>
        <.persona_card
          :for={v <- @game_voices}
          voice={v} game={@game} event={@event}
          selected={@current == v.id} is_default={@default_voice == v.id}
          popular={MapSet.member?(@popular, v.id)}
        />

        <div class="persona-modal__section">Alternatives</div>
        <.persona_card
          :for={v <- @alt}
          voice={v} game={@game} event={@event}
          selected={@current == v.id} is_default={@default_voice == v.id}
          popular={MapSet.member?(@popular, v.id)}
        />
      </div>
    </div>
  </div>
  """
end

attr :voice, :map, required: true
attr :game, :map, required: true
attr :event, :string, required: true
attr :selected, :boolean, required: true
attr :is_default, :boolean, required: true
attr :popular, :boolean, required: true

defp persona_card(assigns) do
  sample =
    case RuleMaven.Voices.loading_phrases(assigns.voice, assigns.game) do
      [p | _] -> p
      _ -> nil
    end

  assigns = assign(assigns, :sample, sample)

  ~H"""
  <button
    type="button"
    class={["persona-card", @selected && "persona-card--selected"]}
    phx-click={@event}
    phx-value-voice={@voice.id}
    data-search={String.downcase("#{@voice.label} #{@voice.description}")}
  >
    <span class="persona-card__emoji" aria-hidden="true">{@voice.emoji}</span>
    <span class="persona-card__body">
      <span class="persona-card__title">
        {@voice.label}
        <span :if={@popular} class="persona-card__badge">🔥 Popular</span>
        <span :if={@is_default} class="persona-card__badge persona-card__badge--star" title="Your default">★</span>
      </span>
      <span :if={@voice.description} class="persona-card__desc">{@voice.description}</span>
      <span :if={@sample} class="persona-card__sample">“{@sample}”</span>
    </span>
    <span :if={@selected} class="persona-card__check" aria-hidden="true">✓</span>
  </button>
  """
end
```

> `RuleMaven.Voices.loading_phrases/2` already exists (`voices.ex:357`) and takes `(voice, game)`; it returns the persona's phrases or a global fallback. If a built-in voice yields only generic phrases you consider noise, that is acceptable for v1 — the description carries the flavor.

- [ ] **Step 4b: Verify no remaining `voice_menu` references**

Run: `grep -n "voice_menu" lib/rule_maven_web/live/game_live/show.ex`
Expected: no matches. If any remain, they are stale call sites — replace with the button (Step 1/2 pattern).

- [ ] **Step 5: CSS** — append to the `≤640px` region and add base styles in `priv/static/assets/css/app.css`:

```css
/* ── Persona picker modal ─────────────────────────────────────────────── */
.persona-modal-backdrop {
  position: fixed; inset: 0; z-index: 3000;
  background: rgba(0,0,0,0.45);
  display: flex; align-items: center; justify-content: center;
  padding: 1rem;
}
.persona-modal {
  background: var(--bg-surface); color: var(--text);
  border: 1px solid var(--border); border-radius: 0.75rem;
  box-shadow: 0 12px 40px rgba(0,0,0,0.35);
  width: 100%; max-width: 420px; max-height: 85vh;
  display: flex; flex-direction: column; overflow: hidden;
}
.persona-modal__head {
  display: flex; align-items: center; justify-content: space-between;
  padding: 0.6rem 0.75rem; border-bottom: 1px solid var(--border);
}
.persona-modal__title { font-weight: 700; font-size: 0.9rem; }
.persona-modal__search {
  margin: 0.6rem 0.75rem 0.4rem; padding: 0.4rem 0.6rem;
  border: 1px solid var(--border); border-radius: 0.5rem;
  background: var(--bg); color: var(--text); font-size: 0.8rem;
}
.persona-modal__scroll { overflow-y: auto; padding: 0 0.5rem 0.6rem; }
.persona-modal__section {
  font-size: 0.55rem; font-weight: 700; letter-spacing: 0.06em;
  text-transform: uppercase; color: var(--text-muted);
  padding: 0.5rem 0.5rem 0.2rem;
}
.persona-modal__section--game { color: var(--accent); }
.persona-card {
  display: flex; align-items: flex-start; gap: 0.55rem; width: 100%;
  text-align: left; background: none; border: 1px solid transparent;
  border-radius: 0.5rem; padding: 0.5rem; cursor: pointer;
  color: var(--text); transition: background 0.12s, border-color 0.12s;
}
.persona-card:hover { background: var(--bg-subtle); }
.persona-card--selected {
  border-color: color-mix(in srgb, var(--accent) 55%, transparent);
  background: color-mix(in srgb, var(--accent) 12%, transparent);
}
.persona-card__emoji { font-size: 1.15rem; line-height: 1.3; flex-shrink: 0; }
.persona-card__body { display: flex; flex-direction: column; gap: 0.1rem; min-width: 0; flex: 1; }
.persona-card__title { font-weight: 700; font-size: 0.8rem; display: flex; align-items: center; gap: 0.35rem; flex-wrap: wrap; }
.persona-card__badge {
  font-size: 0.55rem; font-weight: 700; color: var(--accent);
  background: color-mix(in srgb, var(--accent) 14%, transparent);
  padding: 0.05rem 0.3rem; border-radius: 999px;
}
.persona-card__badge--star { color: #e0a83a; background: none; padding: 0; }
.persona-card__desc { font-size: 0.7rem; color: var(--text-secondary); line-height: 1.3; }
.persona-card__sample { font-size: 0.68rem; color: var(--text-muted); font-style: italic; line-height: 1.3; }
.persona-card__check { color: var(--accent); font-weight: 800; flex-shrink: 0; }
@media (max-width: 640px) {
  .persona-modal { max-width: none; max-height: 88vh; }
}
```

- [ ] **Step 6: Run the Task 3 test — expect pass**

Run: `mix test test/rule_maven_web/live/game_live/persona_modal_test.exs`
Expected: PASS (modal renders, pick records + closes).

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven_web/live/game_live/show.ex priv/static/assets/css/app.css
git commit -m "feat: persona picker modal + cards (replaces voice_menu dropdown)"
```

---

### Task 5: Search-filter JS hook + recently-used verification

**Files:**
- Modify: `priv/static/assets/js/app.js` (add `PersonaFilter` hook, register it)

**Interfaces:**
- Consumes: `#persona-modal-panel` with `[data-persona-filter-input]` and `.persona-card[data-search]`.
- Produces: client-side filtering; no server contract.

- [ ] **Step 1: Add the hook** near the other hook definitions in `app.js`:

```javascript
// Filters persona cards in the picker modal by label/description text. Purely
// client-side so typing never round-trips; the input is phx-update="ignore".
const PersonaFilter = {
  mounted() {
    const input = this.el.querySelector("[data-persona-filter-input]");
    if (!input) return;
    const apply = () => {
      const q = input.value.trim().toLowerCase();
      this.el.querySelectorAll(".persona-card").forEach((card) => {
        const hit = !q || (card.dataset.search || "").includes(q);
        card.style.display = hit ? "" : "none";
      });
      // Hide a section heading when every following card up to the next
      // heading is filtered out.
      const sections = this.el.querySelectorAll(".persona-modal__section");
      sections.forEach((sec) => {
        let anyVisible = false;
        let n = sec.nextElementSibling;
        while (n && !n.classList.contains("persona-modal__section")) {
          if (n.classList.contains("persona-card") && n.style.display !== "none") anyVisible = true;
          n = n.nextElementSibling;
        }
        sec.style.display = anyVisible ? "" : "none";
      });
    };
    input.addEventListener("input", apply);
    input.focus();
  },
};
```

Register it in the `hooks` object passed to `LiveSocket` (find `hooks: {` / `Hooks =` in `app.js` and add `PersonaFilter`).

> Mobile note (from memory `mobile-support-patterns`): do NOT autofocus on touch. Wrap the `input.focus()` with `if (!matchMedia("(pointer: coarse)").matches) input.focus();` so phones don't pop the keyboard.

- [ ] **Step 2: Manual/browser check**

Start server, at 390px open the modal, type in the search box → non-matching cards hide, empty sections hide, input keeps focus/value across a LiveView update. (Full browser recipe in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/js/app.js
git commit -m "feat: client-side persona search filter"
```

---

### Task 6: End-to-end browser verification

**Files:** none (verification only). Uses puppeteer + auto-login (see `docs`/memory recipe).

- [ ] **Step 1: Run the full relevant test set**

Run: `mix test test/rule_maven/voices_test.exs test/rule_maven_web/live/game_live/persona_modal_test.exs`
Expected: all PASS.

- [ ] **Step 2: Browser sweep** at 390×844 and 1200×800 on a Ready game with sources (e.g. Catan):
  - Mint a login token (`Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user_id)`), visit `/auto-login?token=…`, then `/games/<slug>`.
  - Open the composer persona button → assert `#persona-modal` is centered, `getBoundingClientRect().right <= innerWidth` and `left >= 0` (no overflow) at both sizes.
  - Type in search → assert some `.persona-card` become `display:none`.
  - Pick a persona → modal closes, composer button label updates.
  - Open a per-answer switcher on an answered thread → same modal, `set_voice` path.
  - Re-open → the just-picked persona shows in a "Recently used" strip.

- [ ] **Step 3: Confirm popularity badge** by inserting a few events for one voice (or picking it several times across users) and re-opening → 🔥 on that card.

- [ ] **Step 4: Final commit if any tweaks**

```bash
git add -A && git commit -m "test: persona modal browser verification tweaks"
```

---

## Self-Review Notes

- **Spec coverage:** modal (T4), both pickers (T4 steps 1–2), tracking table (T1), popularity badge (T2/T4), recently-used (T2/T4), descriptions + sample (T4 persona_card), search (T5), event recording best-effort (T1/T3), tests (T1/T2/T3/T6). All covered.
- **Type consistency:** `record_event/3`, `popular_voice_ids/2` (MapSet), `recent_voice_ids/3` (list) used consistently across T3/T4. `persona_modal`/`persona_popular`/`persona_recent` assign names consistent. Event names `open_persona_modal`/`close_persona_modal`/`set_voice`/`set_default_voice` consistent.
- **Deploy:** run the `persona_events` migration in prod; no backfill. No prompt-registry changes.
```
