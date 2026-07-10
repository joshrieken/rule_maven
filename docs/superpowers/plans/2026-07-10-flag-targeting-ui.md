# Flag Targeting UI Implementation Plan (Spec A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin grant a flag to a named user and set a percentage rollout from `/admin/flags`, exposing the actor and percentage gates `fun_with_flags` already supports.

**Architecture:** Add thin gate-facade functions to `RuleMaven.Flags` (`gates/1`, `grant_actor/2`, `revoke_actor/2`, `set_percentage/2`), then wire per-flag controls into the existing `AdminLive.Flags` LiveView. No new data model — actor and percentage gates live in `fun_with_flags_toggles`.

**Tech Stack:** Elixir, Phoenix LiveView, `fun_with_flags` 1.13, ExUnit.

## Global Constraints

- Authorization: `RuleMaven.Users.can?(user, :admin)` at mount AND re-checked in every event handler (an event on an open socket must not trust mount-time gating). Capability, not role string.
- Every gate change writes to the audit log: `RuleMaven.Audit.log(user, action, target_label: id_string)`.
- `fun_with_flags` percentage gates require `0.0 < ratio < 1.0` — both `0.0` and `1.0` raise `InvalidTargetError` (verified in `deps/fun_with_flags/lib/fun_with_flags/gate.ex:42-48`). The slider is 1–99; 0 clears; 100% is the boolean toggle's job.
- Username resolution: `RuleMaven.Users.get_user_by_username/1` (returns `%User{}` or nil).
- `FunWithFlags` verified API: `enable(flag, for_actor: user)`, `enable(flag, for_percentage_of: {:actors, ratio})`, `clear(flag, for_actor: user)`, `clear(flag, for_percentage: true)`, `get_flag(flag) -> %FunWithFlags.Flag{gates: [...]} | nil`. Gate struct: `%FunWithFlags.Gate{type, for, enabled}`, `type` ∈ `:boolean | :actor | :percentage_of_actors | :group`; actor `for` is `"user:<id>"`, percentage `for` is the ratio float.
- Actor id format is `"user:#{id}"` (the `FunWithFlags.Actor` impl for `User`).
- All flag tests `async: false` with `FunWithFlags.clear/1` cleanup — the Ecto store does not roll back with the SQL sandbox. `config/test.exs` already disables the ETS cache.
- No new inline button styles beyond the existing `btn-sm`/`btn-primary`/`btn-secondary`/`btn-outline` vocabulary.

---

## File Structure

- Modify: `lib/rule_maven/flags.ex` — add `gates/1`, `grant_actor/2`, `revoke_actor/2`, `set_percentage/2`.
- Modify: `lib/rule_maven_web/live/admin_live/flags.ex` — per-flag grant input, actor list, percentage slider, event handlers, expanded `load_flags/0`.
- Test: `test/rule_maven/flags_targeting_test.exs` (facade), `test/rule_maven_web/live/admin_live/flags_targeting_test.exs` (LiveView).

---

## Task 1: Facade gate functions

**Files:**
- Modify: `lib/rule_maven/flags.ex`
- Test: `test/rule_maven/flags_targeting_test.exs`

**Interfaces:**
- Consumes: `FunWithFlags`, `RuleMaven.Flags.Registry.fetch!/1`, `RuleMaven.Users.User`.
- Produces:
  - `Flags.grant_actor(flag, %User{}) :: {:ok, true} | {:error, any}`
  - `Flags.revoke_actor(flag, %User{}) :: :ok | {:error, any}`
  - `Flags.set_percentage(flag, ratio :: float) :: {:ok, true} | :ok` (clears when `ratio <= 0`; raises `ArgumentError` when `ratio >= 1`)
  - `Flags.gates(flag) :: %{boolean: boolean | nil, percentage: float | nil, actors: [String.t]}`

- [ ] **Step 1: Write the failing tests**

Create `test/rule_maven/flags_targeting_test.exs`:

```elixir
defmodule RuleMaven.FlagsTargetingTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags

  defp user do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "user"
      })

    u
  end

  test "grant_actor makes the flag on for that user even when boolean is off" do
    u = user()
    other = user()
    {:ok, _} = Flags.disable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)

    assert Flags.enabled?(:tool_quiz, u)
    refute Flags.enabled?(:tool_quiz, other)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "revoke_actor reverts the user to the boolean outcome" do
    u = user()
    {:ok, _} = Flags.disable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)
    assert Flags.enabled?(:tool_quiz, u)

    :ok = Flags.revoke_actor(:tool_quiz, u)
    refute Flags.enabled?(:tool_quiz, u)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "set_percentage writes a percentage gate; 0 clears it; >=1 raises" do
    {:ok, _} = Flags.set_percentage(:tool_quiz, 0.25)
    assert Flags.gates(:tool_quiz).percentage == 0.25

    :ok = Flags.set_percentage(:tool_quiz, 0)
    assert Flags.gates(:tool_quiz).percentage == nil

    assert_raise ArgumentError, fn -> Flags.set_percentage(:tool_quiz, 1.0) end
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "gates/1 normalizes boolean, actor, and percentage gates" do
    u = user()
    {:ok, _} = Flags.enable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)
    {:ok, _} = Flags.set_percentage(:tool_quiz, 0.4)

    g = Flags.gates(:tool_quiz)
    assert g.boolean == true
    assert g.percentage == 0.4
    assert "user:#{u.id}" in g.actors
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "gates/1 on an unregistered flag raises (registry validation)" do
    assert_raise KeyError, fn -> Flags.gates(:not_a_real_flag) end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/rule_maven/flags_targeting_test.exs 2>&1 | tee tmp/flags_targeting.log`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement the facade functions**

In `lib/rule_maven/flags.ex`, add after `enable_for_admins/1`:

```elixir
  @doc "Grant `flag` to a specific user (actor gate). Overrides the boolean/percentage."
  def grant_actor(flag, %RuleMaven.Users.User{} = user) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, for_actor: user)
  end

  @doc "Remove a user's actor gate, reverting them to the boolean/percentage outcome."
  def revoke_actor(flag, %RuleMaven.Users.User{} = user) do
    Registry.fetch!(flag)
    FunWithFlags.clear(flag, for_actor: user)
  end

  @doc """
  Set the percentage-of-actors rollout for `flag`. `ratio <= 0` clears the gate;
  `ratio >= 1` raises (100% is the boolean gate's job — `fun_with_flags` rejects 1.0).
  """
  def set_percentage(flag, ratio) when is_number(ratio) do
    Registry.fetch!(flag)

    cond do
      ratio <= 0 -> FunWithFlags.clear(flag, for_percentage: true)
      ratio >= 1 -> raise ArgumentError, "percentage must be < 1.0 (use the boolean toggle for 100%)"
      true -> FunWithFlags.enable(flag, for_percentage_of: {:actors, ratio / 1})
    end
  end

  @doc """
  Normalized view of a flag's gates for display:
  `%{boolean: bool | nil, percentage: float | nil, actors: ["user:<id>", ...]}`.
  """
  def gates(flag) do
    Registry.fetch!(flag)

    gate_list =
      case FunWithFlags.get_flag(flag) do
        %FunWithFlags.Flag{gates: gates} -> gates
        _ -> []
      end

    Enum.reduce(gate_list, %{boolean: nil, percentage: nil, actors: []}, fn gate, acc ->
      case gate do
        %FunWithFlags.Gate{type: :boolean, enabled: e} -> %{acc | boolean: e}
        %FunWithFlags.Gate{type: :percentage_of_actors, for: r} -> %{acc | percentage: r}
        %FunWithFlags.Gate{type: :actor, for: target, enabled: true} -> %{acc | actors: [target | acc.actors]}
        _ -> acc
      end
    end)
  end
```

Note: `ratio / 1` coerces an integer ratio to float (fun_with_flags requires a float). The
guard is `is_number` so a caller may pass `0` (cleared) without a FunctionClauseError.

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/rule_maven/flags_targeting_test.exs 2>&1 | tee tmp/flags_targeting.log`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/flags.ex test/rule_maven/flags_targeting_test.exs
git commit -m "feat(flags): actor-grant and percentage facade functions + gates/1"
```

---

## Task 2: Wire the targeting controls into /admin/flags

**Files:**
- Modify: `lib/rule_maven_web/live/admin_live/flags.ex`
- Test: `test/rule_maven_web/live/admin_live/flags_targeting_test.exs`

**Interfaces:**
- Consumes: `Flags.gates/1`, `Flags.grant_actor/2`, `Flags.revoke_actor/2`, `Flags.set_percentage/2`, `Users.get_user_by_username/1`, `Users.get_user/1`.
- Produces: the LiveView; no downstream consumers.

- [ ] **Step 1: Write the failing LiveView tests**

Create `test/rule_maven_web/live/admin_live/flags_targeting_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.FlagsTargetingTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(role) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: role
      })

    u
  end

  test "granting a user by username adds an actor gate", %{conn: conn} do
    admin = user("admin")
    target = user("user")
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#grant-tool_quiz", %{"username" => target.username})
    |> render_submit()

    assert RuleMaven.Flags.enabled?(:tool_quiz, target)
    assert render(view) =~ target.username
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "unknown username flashes and writes nothing", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    html =
      view
      |> form("#grant-tool_quiz", %{"username" => "nobody_here"})
      |> render_submit()

    assert html =~ "No user named"
    assert RuleMaven.Flags.gates(:tool_quiz).actors == []
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "setting a percentage writes a percentage gate", %{conn: conn} do
    admin = user("admin")
    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/flags")

    view
    |> form("#pct-tool_quiz", %{"percentage" => "30"})
    |> render_submit()

    assert RuleMaven.Flags.gates(:tool_quiz).percentage == 0.3
  after
    FunWithFlags.clear(:tool_quiz)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/rule_maven_web/live/admin_live/flags_targeting_test.exs 2>&1 | tee tmp/flags_ui_targeting.log`
Expected: FAIL — no `#grant-tool_quiz` / `#pct-tool_quiz` forms.

- [ ] **Step 3: Expand load_flags/0 to include gates**

In `lib/rule_maven_web/live/admin_live/flags.ex`, replace `load_flags/0` (lines 40-44):

```elixir
  defp load_flags do
    Registry.all()
    |> Enum.map(fn f ->
      f
      |> Map.put(:on?, Flags.enabled?(f.id, nil))
      |> Map.put(:gates, gate_view(f.id))
    end)
    |> Enum.group_by(& &1.kind)
  end

  # Resolve actor targets ("user:<id>") back to usernames for display.
  defp gate_view(flag) do
    g = Flags.gates(flag)

    actors =
      Enum.map(g.actors, fn "user:" <> id ->
        case Integer.parse(id) do
          {int, _} -> %{id: int, username: username_for(int)}
          :error -> %{id: nil, username: id}
        end
      end)

    %{percentage: g.percentage, actors: actors}
  end

  defp username_for(user_id) do
    case Users.get_user(user_id) do
      %{username: name} -> name
      _ -> "user ##{user_id}"
    end
  end
```

- [ ] **Step 4: Add the three event handlers**

In `lib/rule_maven_web/live/admin_live/flags.ex`, after the existing `handle_event("toggle", ...)` clause (line 38), add:

```elixir
  @impl true
  def handle_event("grant_actor", %{"id" => id, "username" => username}, socket) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)

      case Users.get_user_by_username(String.trim(username)) do
        nil ->
          put_flash(socket, :error, "No user named #{username}.")

        user ->
          Flags.grant_actor(flag, user)
          Audit.log(socket.assigns.current_user, "flag.grant_actor", target_label: id)

          socket
          |> assign(flags: load_flags())
          |> put_flash(:info, "Granted #{id} to #{user.username}.")
      end
    end)
  end

  @impl true
  def handle_event("revoke_actor", %{"id" => id, "user-id" => user_id}, socket) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)

      case Users.get_user(String.to_integer(user_id)) do
        nil ->
          socket

        user ->
          Flags.revoke_actor(flag, user)
          Audit.log(socket.assigns.current_user, "flag.revoke_actor", target_label: id)

          socket
          |> assign(flags: load_flags())
          |> put_flash(:info, "Revoked #{id} from #{user.username}.")
      end
    end)
  end

  @impl true
  def handle_event("set_percentage", %{"id" => id, "percentage" => pct}, socket) do
    with_admin(socket, fn ->
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)
      n = String.to_integer(pct)

      Flags.set_percentage(flag, n / 100)
      Audit.log(socket.assigns.current_user, "flag.set_percentage", target_label: "#{id}=#{n}")

      socket
      |> assign(flags: load_flags())
      |> put_flash(:info, "#{id} set to #{n}%.")
    end)
  end

  # Re-check admin capability on every event, then run fun/0 which returns a socket.
  defp with_admin(socket, fun) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:noreply, fun.()}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end
```

Note: leave the existing `handle_event("toggle", ...)` clause as-is (do not refactor it into
`with_admin` in this task — minimize churn; a reviewer can suggest it separately).

- [ ] **Step 5: Render the targeting controls**

In `lib/rule_maven_web/live/admin_live/flags.ex`, replace the `<li>` block (lines 60-73) with:

```heex
            <li style="padding:0.6rem 0;border-bottom:1px solid var(--border)">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:1rem">
                <span>
                  <strong>{f.label}</strong>
                  <code class="text-muted">{f.id}</code>
                </span>
                <button
                  type="button"
                  class={["btn-sm", if(f.on?, do: "btn-primary", else: "btn-secondary")]}
                  phx-click="toggle"
                  phx-value-id={f.id}
                >
                  {if f.on?, do: "On", else: "Off"}
                </button>
              </div>

              <div style="display:flex;flex-wrap:wrap;gap:1rem;margin-top:0.5rem;font-size:0.85rem">
                <form id={"grant-#{f.id}"} phx-submit="grant_actor" style="display:flex;gap:0.35rem;align-items:center">
                  <input type="hidden" name="id" value={f.id} />
                  <input type="text" name="username" placeholder="username" class="input-sm" />
                  <button type="submit" class="btn-xs btn-outline">Grant</button>
                </form>

                <form id={"pct-#{f.id}"} phx-submit="set_percentage" style="display:flex;gap:0.35rem;align-items:center">
                  <input type="hidden" name="id" value={f.id} />
                  <input type="number" name="percentage" min="1" max="99" value={pct_value(f)} style="width:4rem" />
                  <span>%</span>
                  <button type="submit" class="btn-xs btn-outline">Set</button>
                  <button
                    type="button"
                    class="btn-xs btn-secondary"
                    phx-click="set_percentage"
                    phx-value-id={f.id}
                    phx-value-percentage="0"
                  >Clear</button>
                </form>
              </div>

              <div :if={f.gates.actors != []} style="margin-top:0.35rem;font-size:0.8rem" class="text-secondary">
                Granted to:
                <span :for={a <- f.gates.actors} style="margin-right:0.5rem">
                  {a.username}
                  <button
                    type="button"
                    class="btn-xs btn-remove"
                    phx-click="revoke_actor"
                    phx-value-id={f.id}
                    phx-value-user-id={a.id}
                    title={"Revoke #{a.username}"}
                  >×</button>
                </span>
              </div>
            </li>
```

And add the `pct_value/1` helper next to `load_flags/0`:

```elixir
  defp pct_value(%{gates: %{percentage: nil}}), do: nil
  defp pct_value(%{gates: %{percentage: r}}), do: round(r * 100)
```

- [ ] **Step 6: Verify the button/input classes exist**

Run: `grep -oE "\.(btn-xs|btn-outline|btn-remove|input-sm)" priv/static/assets/css/app.css | sort -u`
Expected: `btn-xs`, `btn-outline`, `btn-remove` present. If `input-sm` is absent, drop that class (the input works without it — a plain `<input>` inherits base styling). Do not invent a class; remove it if it does not exist.

- [ ] **Step 7: Run the LiveView tests**

Run: `mix test test/rule_maven_web/live/admin_live/flags_targeting_test.exs 2>&1 | tee tmp/flags_ui_targeting.log`
Expected: PASS (3 tests). Also re-run the existing flags LiveView test for no regression:
`mix test test/rule_maven_web/live/admin_live/flags_test.exs 2>&1 | tee -a tmp/flags_ui_targeting.log`

- [ ] **Step 8: Mobile check (standing rule: verify UI at 390px)**

The controls use `flex-wrap:wrap`, so they reflow on narrow screens. Confirm no horizontal
overflow by eye if a dev server is handy; otherwise trust the wrap. No fixed widths except
the 4rem percentage input, which fits at 390px. Note in the commit that this was reasoned,
not browser-verified, unless you ran it.

- [ ] **Step 9: Commit**

```bash
git add lib/rule_maven_web/live/admin_live/flags.ex test/rule_maven_web/live/admin_live/flags_targeting_test.exs
git commit -m "feat(flags): per-user grant + percentage controls on /admin/flags"
```

---

## Self-Review Notes

**Spec coverage:**
- Grant-to-user (actor gate) + revoke → Task 1 (`grant_actor`/`revoke_actor`), Task 2 (UI) ✓
- Percentage slider 1–99, 0 clears, 100% → boolean → Task 1 (`set_percentage`), Task 2 (input min=1, Clear button) ✓
- `gates/1` normalized read + username resolution → Task 1, Task 2 (`gate_view`/`username_for`) ✓
- Audit log on every change → Task 2 handlers ✓
- Admin re-check on every event → Task 2 `with_admin/2` ✓
- Registry validation before acting → both tasks (`Registry.fetch!`) ✓
- async:false + clear cleanup → both test files ✓

**Known verify-in-place points flagged inline:** `input-sm` class existence (Task 2 Step 6), mobile overflow (Step 8). Each has an explicit check, not a guess.

**Deferred to Spec B:** everything experiment/variant-related.
