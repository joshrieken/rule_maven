defmodule RuleMavenWeb.AdminLive.Index do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Users, Games, Settings, Audit}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok,
       assign(socket,
         page_title: "Admin",
         review_backlog: Games.needs_review_count(),
         publish_backlog: Games.publish_pending_count(),
         flag_backlog: Games.count_pending_flags(),
         asks_disabled: not RuleMaven.Flags.enabled?(:asks),
         email_disabled: not RuleMaven.Flags.enabled?(:outbound_email),
         mail_from: Settings.mail_from(),
         public_url: Settings.public_url(),
         mail_dev_live: Settings.mail_dev_live?(),
         resend_key_set: Settings.resend_api_key() != nil,
         dev_routes: Application.get_env(:rule_maven, :dev_routes, false),
         super_admin?: Users.can?(socket.assigns.current_user, :superadmin)
       )}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle_asks", _params, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      disable? = not socket.assigns.asks_disabled
      if disable?, do: RuleMaven.Flags.disable(:asks), else: RuleMaven.Flags.enable(:asks)

      Audit.log(
        socket.assigns.current_user,
        if(disable?, do: "flag.disable", else: "flag.enable"),
        target_label: "asks"
      )

      {:noreply,
       socket
       |> assign(asks_disabled: disable?)
       |> put_flash(:info, if(disable?, do: "Asks paused.", else: "Asks resumed."))}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("toggle_email", _params, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      disable? = not socket.assigns.email_disabled

      if disable?,
        do: RuleMaven.Flags.disable(:outbound_email),
        else: RuleMaven.Flags.enable(:outbound_email)

      Audit.log(
        socket.assigns.current_user,
        if(disable?, do: "flag.disable", else: "flag.enable"),
        target_label: "outbound_email"
      )

      {:noreply,
       socket
       |> assign(email_disabled: disable?)
       |> put_flash(:info, if(disable?, do: "Email paused.", else: "Email resumed."))}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("toggle_mail_dev_live", _params, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      live? = not socket.assigns.mail_dev_live
      Settings.set_mail_dev_live(live?)
      {:noreply, assign(socket, mail_dev_live: live?)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("save_resend_key", %{"resend_api_key" => key}, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      case String.trim(key) do
        "" ->
          {:noreply, put_flash(socket, :error, "Enter a key, or use Clear to remove it.")}

        key ->
          Settings.set_resend_api_key(key)
          Audit.log(socket.assigns.current_user, "email.set_resend_api_key", metadata: %{key_set: true})

          {:noreply,
           socket
           |> assign(resend_key_set: true)
           |> put_flash(:info, "Resend key saved.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("clear_resend_key", _params, socket) do
    if Users.can?(socket.assigns.current_user, :superadmin) do
      Settings.set_resend_api_key("")
      Audit.log(socket.assigns.current_user, "email.set_resend_api_key", metadata: %{key_set: false})

      {:noreply,
       socket
       |> assign(resend_key_set: Settings.resend_api_key() != nil)
       |> put_flash(:info, "Resend key cleared (falls back to env var if set).")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("save_public_url", %{"public_url" => url}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      url = String.trim(url)

      if url =~ ~r"^https?://[^\s]+$" do
        Settings.set_public_url(url)
        Audit.log(socket.assigns.current_user, "settings.set_public_url", metadata: %{public_url: url})

        {:noreply,
         socket
         |> assign(public_url: Settings.public_url())
         |> put_flash(:info, "Public URL saved.")}
      else
        {:noreply, put_flash(socket, :error, "Enter a valid URL (http:// or https://).")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def handle_event("save_mail_from", %{"mail_from" => from}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      from = String.trim(from)

      if from =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ do
        Settings.set_mail_from(from)

        Audit.log(socket.assigns.current_user, "email.set_mail_from",
          metadata: %{mail_from: from}
        )

        {:noreply, socket |> assign(mail_from: from) |> put_flash(:info, "Sender saved.")}
      else
        {:noreply, put_flash(socket, :error, "Enter a valid email address.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/"} class="back-link">&larr; Back to games</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 1rem">Admin Dashboard</h1>

      <div
        :if={@super_admin?}
        style={"display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:0.75rem 1rem;margin-bottom:1rem;border-radius:0.5rem;border:1px solid #{if @asks_disabled, do: "var(--danger,#c0392b)", else: "var(--border)"};background:var(--bg-surface)"}
      >
        <div>
          <div style="font-weight:700;font-size:0.85rem;color:var(--text)">
            {if @asks_disabled, do: "⏸️ Asks are paused", else: "▶️ Asks are live"}
          </div>
          <div style="font-size:0.75rem;color:var(--text-muted)">
            Kill switch for new LLM answers. Existing answers keep serving; admins can still ask.
          </div>
        </div>
        <button
          type="button"
          phx-click="toggle_asks"
          data-confirm={
            if !@asks_disabled, do: "Pause all new question answering for users?", else: false
          }
          class="btn-sm"
          style={"flex-shrink:0;border:1px solid #{if @asks_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};color:#{if @asks_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};background:none"}
        >
          {if @asks_disabled, do: "Resume asks", else: "Pause asks"}
        </button>
      </div>

      <div
        :if={@super_admin?}
        style={"display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:0.75rem 1rem;margin-bottom:1rem;border-radius:0.5rem;border:1px solid #{if @email_disabled, do: "var(--danger,#c0392b)", else: "var(--border)"};background:var(--bg-surface)"}
      >
        <div style="min-width:0">
          <div style="font-weight:700;font-size:0.85rem;color:var(--text)">
            {if @email_disabled, do: "⏸️ Email is paused", else: "📧 Email is on"}
          </div>
          <div style="font-size:0.75rem;color:var(--text-muted)">
            Kill switch for outbound email (confirmation, password reset). Skipped sends are logged; callers still succeed.
          </div>
        </div>
        <button
          type="button"
          phx-click="toggle_email"
          data-confirm={
            if !@email_disabled,
              do: "Pause all outbound email (confirmation, password reset)?",
              else: false
          }
          class="btn-sm"
          style={"flex-shrink:0;border:1px solid #{if @email_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};color:#{if @email_disabled, do: "var(--green)", else: "var(--danger,#c0392b)"};background:none"}
        >
          {if @email_disabled, do: "Resume email", else: "Pause email"}
        </button>
      </div>

      <div style="padding:0.75rem 1rem;margin-bottom:1rem;border-radius:0.5rem;border:1px solid var(--border);background:var(--bg-surface)">
        <div style="font-weight:700;font-size:0.85rem;color:var(--text)">
          📧 Email settings
        </div>
        <div style="font-size:0.75rem;color:var(--text-muted);margin-bottom:0.6rem">
          <span :if={!@resend_key_set} style="color:var(--danger,#c0392b)">
            Resend key not set — real sends are skipped.
          </span>
          <span :if={@resend_key_set}>Resend key: set.</span>
        </div>

        <form
          id="mail-from-form"
          phx-submit="save_mail_from"
          style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap;margin-top:0.6rem"
        >
          <label for="mail_from" style="font-size:0.75rem;color:var(--text-muted);flex-shrink:0">
            Sender address
          </label>
          <input
            id="mail_from"
            name="mail_from"
            type="email"
            value={@mail_from}
            style="flex:1;min-width:12rem;font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.35rem;background:var(--bg);color:var(--text)"
          />
          <button type="submit" class="btn-sm btn-outline" style="flex-shrink:0">Save</button>
        </form>

        <form
          :if={@super_admin?}
          id="resend-key-form"
          phx-submit="save_resend_key"
          style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap;margin-top:0.6rem"
        >
          <label for="resend_api_key" style="font-size:0.75rem;color:var(--text-muted);flex-shrink:0">
            Resend API key
          </label>
          <input
            id="resend_api_key"
            name="resend_api_key"
            type="password"
            value=""
            placeholder={if @resend_key_set, do: "•••••••••• (set — enter a new key to replace)", else: "re_..."}
            autocomplete="off"
            style="flex:1;min-width:12rem;font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.35rem;background:var(--bg);color:var(--text)"
          />
          <button type="submit" class="btn-sm btn-outline" style="flex-shrink:0">Save</button>
          <button
            :if={@resend_key_set}
            type="button"
            phx-click="clear_resend_key"
            data-confirm="Clear the Resend key? Falls back to RESEND_API_KEY env var if set."
            class="btn-sm"
            style="flex-shrink:0;border:1px solid var(--danger,#c0392b);color:var(--danger,#c0392b);background:none"
          >
            Clear
          </button>
        </form>

        <label
          :if={@dev_routes}
          style="display:flex;align-items:center;gap:0.4rem;margin-top:0.6rem;font-size:0.75rem;color:var(--text-muted);cursor:pointer"
        >
          <input type="checkbox" checked={@mail_dev_live} phx-click="toggle_mail_dev_live" />
          Send real email from dev via Resend (off = <code>/dev/mailbox</code>
          preview)
        </label>
      </div>

      <div style="padding:0.75rem 1rem;margin-bottom:1rem;border-radius:0.5rem;border:1px solid var(--border);background:var(--bg-surface)">
        <div style="font-weight:700;font-size:0.85rem;color:var(--text)">
          🌐 Public URL
        </div>
        <div style="font-size:0.75rem;color:var(--text-muted);margin-bottom:0.6rem">
          The app's canonical domain — used to build every absolute link the app sends out (email confirmation/reset links, group invite links, etc).
        </div>

        <form
          id="public-url-form"
          phx-submit="save_public_url"
          style="display:flex;align-items:center;gap:0.5rem;flex-wrap:wrap"
        >
          <label for="public_url" style="font-size:0.75rem;color:var(--text-muted);flex-shrink:0">
            Public URL
          </label>
          <input
            id="public_url"
            name="public_url"
            type="text"
            value={@public_url}
            placeholder="https://rulemaven.app"
            style="flex:1;min-width:12rem;font-size:0.8rem;padding:0.3rem 0.5rem;border:1px solid var(--border);border-radius:0.35rem;background:var(--bg);color:var(--text)"
          />
          <button type="submit" class="btn-sm btn-outline" style="flex-shrink:0">Save</button>
        </form>
      </div>

      <.section title="Review">
        <.card
          navigate={
            if @review_backlog > 0,
              do: ~p"/admin/questions?status=needs_review",
              else: ~p"/admin/questions"
          }
          icon="💬"
          title="Questions"
          desc="Browse, filter, and delete user questions."
          badge={@review_backlog > 0 && "#{@review_backlog} to review"}
          badge_title="Community answers flagged stale by a rulebook change, awaiting re-approval"
        />
        <.card
          navigate={
            if @publish_backlog > 0,
              do: ~p"/admin/questions?status=publish_pending",
              else: ~p"/admin/questions"
          }
          icon="🚦"
          title="Publish gate"
          desc="Rows stuck behind the automated publish screen; force-publish to override."
          badge={@publish_backlog > 0 && "#{@publish_backlog} stuck"}
          badge_title="Citation-valid rows still unbrowsable, waiting on or stuck behind PublishCheckWorker"
        />
        <.card
          navigate={~p"/admin/moderation"}
          icon="🚩"
          title="Moderation"
          desc="Per-user abuse signals, vote rings, suspend/pull-answers."
          badge={@flag_backlog > 0 && "#{@flag_backlog} reported"}
          badge_title="Answers users reported as wrong or unhelpful, awaiting review"
        />
        <.card
          navigate={~p"/admin/audit"}
          icon="📜"
          title="Audit Log"
          desc="Append-only record of sensitive admin actions."
        />
        <.card
          navigate={~p"/admin/takedowns"}
          icon="⛔"
          title="DMCA Takedowns"
          desc="Remove games on copyright complaint; reason + complainant logged."
        />
      </.section>

      <.section title="Manage">
        <.card
          navigate={~p"/admin/users"}
          icon="👥"
          title="Manage Users"
          desc="Promote users to admins. Manage roles."
        />
        <.card
          navigate={~p"/admin/groups"}
          icon="🧑‍🤝‍🧑"
          title="Manage Groups"
          desc="View every crew, manage members, rename or delete."
        />
        <.card
          navigate={~p"/admin/invites"}
          icon="🎟️"
          title="Invite Codes"
          desc="Generate invite codes for new user registration."
        />
        <.card
          navigate={~p"/admin/catalog"}
          icon="📦"
          title="Game Catalog"
          desc="Bulk-import the full BoardGameGeek catalog (~150k games)."
        />
        <.card
          navigate={~p"/admin/requests"}
          icon="🙋"
          title="Support Requests"
          desc="Games users want supported, ranked by demand."
        />
      </.section>

      <.section title="AI & Integrations">
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/llm"}
          icon="🤖"
          title="LLM Provider"
          desc="Provider, API keys, answer/cleanup/vision models."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/embeddings"}
          icon="🧬"
          title="Embeddings & Proxy"
          desc="Embedding provider/model and LLM proxy routing."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/automation"}
          icon="🧵"
          title="Automation"
          desc="Auto-approve thresholds for uploads and FAQ drafts."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/bgg"}
          icon="🎲"
          title="BoardGameGeek"
          desc="API token and login used to import games and PDFs."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/prompts"}
          icon="📝"
          title="Prompts"
          desc="Edit the LLM prompts used across the app."
        />
      </.section>

      <.section title="System">
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/security"}
          icon="🛡️"
          title="Security"
          desc="Blocked questions and injection pattern management."
        />
        <.card
          navigate={~p"/admin/health"}
          icon="❤️‍🩹"
          title="System Health"
          desc="Oban queues, LLM error rate, today's spend vs alert."
        />
        <.card
          navigate={~p"/admin/usage"}
          icon="📊"
          title="Usage & Cost"
          desc="LLM token spend per user, daily budget cap, and estimated savings."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/db"}
          icon="🗄️"
          title="DB Admin"
          desc="Browse, edit, and manage database tables directly."
        />
        <.card
          navigate={~p"/admin/themes"}
          icon="🎨"
          title="Theme Usage"
          desc="Which themes users have selected."
        />
        <.card
          :if={@super_admin?}
          navigate={~p"/admin/flags"}
          icon="🚩"
          title="Feature Flags"
          desc="Toggle features on or off for everyone."
        />
        <.card
          :if={@super_admin?}
          href="/oban"
          target="_blank"
          icon="⚙️"
          title="Oban Dashboard ↗"
          desc="Background job queue and processing dashboard."
        />
      </.section>
    </div>
    """
  end

  slot :inner_block, required: true
  attr :title, :string, required: true

  defp section(assigns) do
    ~H"""
    <h2 style="font-size:0.7rem;font-weight:700;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-muted);margin:1.25rem 0 0.5rem">
      {@title}
    </h2>
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(14rem,1fr));gap:0.75rem">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :target, :string, default: nil
  attr :badge, :any, default: nil
  attr :badge_title, :string, default: nil

  defp card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      href={@href}
      target={@target}
      style="position:relative;background:var(--bg-surface);border:1px solid var(--border);border-radius:0.5rem;padding:1.25rem;text-decoration:none;display:block"
    >
      <span
        :if={@badge}
        title={@badge_title}
        style="position:absolute;top:0.6rem;right:0.6rem;background:var(--danger,#c0392b);color:#fff;font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.45rem"
      >
        {@badge}
      </span>
      <div style="font-size:1.5rem;margin-bottom:0.4rem">{@icon}</div>
      <div style="font-weight:700;font-size:0.9rem;color:var(--text);margin-bottom:0.2rem">
        {@title}
      </div>
      <div style="font-size:0.8rem;color:var(--text-muted)">{@desc}</div>
    </.link>
    """
  end
end
