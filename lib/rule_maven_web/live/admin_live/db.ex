defmodule RuleMavenWeb.AdminLive.Db do
  use RuleMavenWeb, :live_view

  alias Ecto.Adapters.SQL
  alias RuleMaven.{Audit, Repo, Users}

  # Raw browse caps at this many rows; large tables truncate (newest-first).
  @row_limit 500
  @redaction_marker "«redacted»"

  # Writes through this raw editor are ALLOWLISTED, not denylisted. A denylist
  # fails open: the next migration adds a credential-bearing table and it is
  # silently hand-editable. Default-deny means a new table is read-only until
  # someone adds it here on purpose.
  #
  # Deliberately absent, and never to be added:
  #   * users, user_tokens — identity. Roles, password hashes and session
  #                          cutoffs are not raw-editable; an admin who could
  #                          UPDATE users.role could mint themselves a super
  #                          admin and undo every guard in Users.
  #   * audit_logs         — append-only by contract; editing here would void
  #                          the forensic guarantee the audit story rests on.
  #   * schema_migrations  — corrupting it breaks migrations / the app.
  #   * oban_*             — the job runtime owns these.
  #
  # Reads stay allowed for every table (browsing is useful); only writes are
  # gated. A super admin bypasses the allowlist entirely — the role exists
  # precisely to have an unrestricted escape hatch, and it is grantable only by
  # `mix rule_maven.grant_superadmin` on the server.
  @writable_tables ~w(
    answer_favorites answer_voices app_settings cheatsheet_versions chunks
    documents expansion_selections extract_calibrations game_categories
    game_expansion_links game_support_requests game_voices games
    house_rule_deltas house_rules injection_patterns invite_codes job_events
    job_runs llm_logs llm_savings persona_events question_category_tags
    question_flags question_mismatch_reports question_votes questions_log
    theme_events user_collections user_favorites
  )

  @doc false
  def __writable_tables__, do: @writable_tables

  @doc false
  # Resolves the table's real column types from the schema so tests exercise the
  # same default-deny path the live console uses.
  def __redact_for_test__(rows, table, superadmin?),
    do: redact_sensitive(rows, fetch_columns(table), superadmin?)

  defp writable?(table, user) do
    Users.can?(user, :admin) and (Users.can?(user, :superadmin) or table in @writable_tables)
  end

  # Re-fetch on every write: a role revoked mid-session must take effect on the
  # already-open socket, not at the next mount.
  defp live_user(socket), do: Users.get_user(socket.assigns.current_user.id)

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      tables = fetch_tables()

      {:ok,
       assign(socket,
         tables: tables,
         table_name: nil,
         columns: [],
         pk_col: nil,
         rows: [],
         delete_id: nil,
         editing_id: nil,
         form_data: %{},
         form_errors: %{},
         mode: nil,
         view_mode: :table,
         row_limit: @row_limit
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    table = params["table"]

    socket =
      if table && table_valid?(table) do
        columns = fetch_columns(table)
        {pk, _} = find_pk(table, columns)

        rows = load_rows(socket, table, columns)

        assign(socket,
          table_name: table,
          columns: columns,
          pk_col: pk,
          rows: rows,
          editing_id: nil,
          mode: nil,
          form_data: %{},
          form_errors: %{}
        )
      else
        assign(socket,
          table_name: nil,
          columns: [],
          pk_col: nil,
          rows: [],
          editing_id: nil,
          mode: nil,
          form_data: %{},
          form_errors: %{}
        )
      end

    {:noreply, socket}
  end

  # ── Events ──

  @impl true
  def handle_event("select_table", %{"table" => t}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/db?table=#{t}")}
  end

  # Delete
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_id: id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_id: nil)}
  end

  def handle_event("delete_row", %{"id" => id}, socket) do
    table = socket.assigns.table_name
    pk = socket.assigns.pk_col

    if writable?(table, live_user(socket)) do
      try do
        # Cast the id to the pk's column type — `id` arrives as a string from
        # phx-value, and binding it raw against an integer pk raises a
        # DBConnection.EncodeError (which the rescue below does not catch), so a
        # delete on any integer-keyed table crashed the LiveView.
        pk_type =
          Enum.find_value(socket.assigns.columns, "integer", fn {c, t} -> c == pk && t end)

        SQL.query!(Repo, "DELETE FROM #{safe(table)} WHERE #{safe(pk)} = $1", [
          parse_for_db(id, pk_type)
        ])

        Audit.log(socket.assigns.current_user, "db.delete",
          target_type: "row",
          target_id: id,
          target_label: "#{table}.#{pk}=#{id}",
          metadata: %{"table" => table}
        )

        rows = load_rows(socket, table, socket.assigns.columns)
        {:noreply, assign(socket, rows: rows, delete_id: nil)}
      rescue
        e in [Postgrex.Error, DBConnection.ConnectionError] ->
          {:noreply, socket |> assign(delete_id: nil) |> put_flash(:error, db_error_message(e))}
      end
    else
      {:noreply,
       socket
       |> assign(delete_id: nil)
       |> put_flash(:error, "#{table} is protected — writes are disabled.")}
    end
  end

  # New
  def handle_event("new_row", _params, socket) do
    {:noreply, assign(socket, mode: :new, editing_id: nil, form_data: %{}, form_errors: %{})}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, mode: nil, editing_id: nil, form_data: %{}, form_errors: %{})}
  end

  def handle_event("toggle_view", _params, socket) do
    next = if socket.assigns.view_mode == :table, do: :extended, else: :table
    {:noreply, assign(socket, view_mode: next)}
  end

  # Edit
  def handle_event("edit_row", %{"id" => id}, socket) do
    table = socket.assigns.table_name
    pk = socket.assigns.pk_col
    superadmin? = Users.can?(live_user(socket), :superadmin)

    # Same masking as the list view — the edit form would otherwise show the raw
    # value in a textarea. A non-superadmin who saves without touching a masked
    # field must not write the mask over the real prose, so a redacted field is
    # dropped from the save (see the "save" handler).
    row =
      table
      |> fetch_row(pk, id, socket.assigns.columns)
      |> then(&([&1] |> redact_sensitive(socket.assigns.columns, superadmin?) |> hd()))

    data =
      Enum.reduce(socket.assigns.columns, %{}, fn {col, _type}, acc ->
        Map.put(acc, col, row[col])
      end)

    {:noreply, assign(socket, mode: :edit, editing_id: id, form_data: data, form_errors: %{})}
  end

  # Form field change
  def handle_event("form_change", %{"field" => field, "value" => value}, socket) do
    data = Map.put(socket.assigns.form_data, field, value)
    {:noreply, assign(socket, form_data: data)}
  end

  # Save
  def handle_event("save", _params, socket) do
    table = socket.assigns.table_name
    pk = socket.assigns.pk_col
    columns = socket.assigns.columns
    mode = socket.assigns.mode
    data = socket.assigns.form_data
    cols_map = Map.new(columns)

    if writable?(table, live_user(socket)) do
      do_save(socket, table, pk, columns, mode, data, cols_map)
    else
      {:noreply,
       socket
       |> assign(mode: nil, editing_id: nil, form_data: %{}, form_errors: %{})
       |> put_flash(:error, "#{table} is protected — writes are disabled.")}
    end
  end

  defp do_save(socket, table, pk, columns, mode, data, cols_map) do
    # Exclude pk from insert/update — and any field still holding the redaction
    # marker, so a non-superadmin who saves an edited row without touching a masked
    # field leaves the real prose intact instead of overwriting it with the mask.
    set_cols =
      cols_map
      |> Map.keys()
      |> Enum.reject(&(&1 == pk or Map.get(data, &1) == @redaction_marker))

    vals = Enum.map(set_cols, &parse_for_db(Map.get(data, &1), cols_map[&1]))

    try do
      case mode do
        :new ->
          placeholders =
            Enum.map_join(
              set_cols,
              ", ",
              &"$#{Enum.find_index(set_cols, fn c -> c == &1 end) + 1}"
            )

          cols_str = Enum.map_join(set_cols, ", ", &safe(&1))

          sql = "INSERT INTO #{safe(table)} (#{cols_str}) VALUES (#{placeholders})"
          SQL.query!(Repo, sql, vals)

        :edit ->
          sets =
            Enum.with_index(set_cols, 1)
            |> Enum.map_join(", ", fn {c, i} -> "#{safe(c)} = $#{i}" end)

          pk_val = parse_for_db(Map.get(data, pk), cols_map[pk])
          sql = "UPDATE #{safe(table)} SET #{sets} WHERE #{safe(pk)} = $#{length(set_cols) + 1}"
          SQL.query!(Repo, sql, vals ++ [pk_val])
      end

      Audit.log(socket.assigns.current_user, "db.#{mode}",
        target_type: "row",
        target_id: socket.assigns.editing_id,
        target_label:
          "#{table}#{if mode == :edit, do: ".#{pk}=#{socket.assigns.editing_id}", else: ""}",
        metadata: %{"table" => table, "columns" => set_cols}
      )

      rows = load_rows(socket, table, columns)

      {:noreply,
       assign(socket, rows: rows, mode: nil, editing_id: nil, form_data: %{}, form_errors: %{})}
    rescue
      # A constraint violation / bad cast used to crash the LiveView; keep the form
      # open and surface the DB error inline instead.
      e in [Postgrex.Error, DBConnection.ConnectionError, ArgumentError] ->
        {:noreply, assign(socket, form_errors: %{base: db_error_message(e)})}
    end
  end

  defp db_error_message(%Postgrex.Error{postgres: %{message: msg}}), do: msg
  defp db_error_message(%Postgrex.Error{} = e), do: Exception.message(e)
  defp db_error_message(e), do: Exception.message(e)

  # ── DB queries ──

  defp fetch_tables do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name",
        []
      )

    Enum.map(rows, fn [t] -> t end)
  end

  defp fetch_columns(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position",
        [table]
      )

    Enum.map(rows, fn [col, type] -> {col, type} end)
  end

  defp find_pk(table, columns) do
    has_id = Enum.any?(columns, fn {c, _} -> c == "id" end)

    if has_id do
      {"id", "integer"}
    else
      query_pk_constraint(table, columns)
    end
  end

  defp query_pk_constraint(table, columns) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name WHERE tc.table_schema = 'public' AND tc.table_name = $1 AND tc.constraint_type = 'PRIMARY KEY'",
        [table]
      )

    case rows do
      [[pk] | _] ->
        col_type = Enum.find_value(columns, fn {c, t} -> c == pk && t end)
        {pk, col_type || "integer"}

      [] ->
        {col, type} = hd(columns)
        {col, type}
    end
  end

  # The ONLY way the list view gets its rows. Every sink that assigns `@rows`
  # (initial load, post-save, post-delete) goes through here so sensitive-column
  # masking cannot be forgotten at one call site — which is exactly how the delete
  # path re-rendered raw crew prose after the load path was hardened.
  defp load_rows(socket, table, columns) do
    table
    |> fetch_rows(columns)
    |> redact_sensitive(columns, Users.can?(live_user(socket), :superadmin))
  end

  defp fetch_rows(table, columns) do
    cols = Enum.map_join(columns, ", ", fn {c, _} -> safe(c) end)

    %{rows: rows, columns: col_names} =
      SQL.query!(
        Repo,
        "SELECT #{cols} FROM #{safe(table)} ORDER BY 1 DESC LIMIT #{@row_limit}",
        []
      )

    Enum.map(rows, fn row ->
      Enum.zip(col_names, row) |> Map.new()
    end)
  end

  defp fetch_row(table, pk, id, columns) do
    cols = Enum.map_join(columns, ", ", fn {c, _} -> safe(c) end)

    %{rows: rows, columns: col_names} =
      SQL.query!(
        Repo,
        "SELECT #{cols} FROM #{safe(table)} WHERE #{safe(pk)} = $1",
        [id]
      )

    case rows do
      [row] -> Enum.zip(col_names, row) |> Map.new()
      [] -> %{}
    end
  end

  defp table_valid?(name) do
    name in fetch_tables()
  end

  # This generic console reads EVERY column of EVERY table for any `:admin`. The
  # crew threat model is that even an admin must not read another user's raw crew
  # wording (a crew question/answer can name real people at the table), and the
  # same console also exposes PII (emails), credential hashes, and join secrets.
  #
  # Masking was a hand-curated per-column DENYLIST, which fails OPEN: it leaked one
  # more prose column every review round (answer_voices.content, house_rule_deltas.
  # delta, groups.invite_code, canonical_question, users.email, …) and even listed
  # columns that no longer exist. A denylist cannot converge.
  #
  # So masking is now DEFAULT-DENY by column TYPE: for a plain admin, every
  # text-like / array / json / user-defined / uuid column is masked unless its NAME
  # is in @always_safe_columns (categorical identifiers that are never prose, PII,
  # or a secret). Scalars — integers, floats, booleans, timestamps — are shown by
  # type and never masked. A NEW prose column is therefore hidden until someone
  # proves it safe, the opposite of the failure mode above. A SUPER admin (the
  # documented unrestricted escape hatch, grantable only by mix task) still sees
  # everything.
  @masked_types [
    "text",
    "character",
    "character varying",
    "json",
    "jsonb",
    "bytea",
    "ARRAY",
    "uuid",
    "USER-DEFINED"
  ]

  # Column names always safe to show regardless of type: categorical/identifier
  # text that is never user prose, PII, or a secret. Keep this tight — when in
  # doubt, leave a column out and let it mask (fail closed); superadmin can still
  # read it.
  # NB: `name` is deliberately NOT here. It reads safe (game/category titles) until
  # you hit `groups.name` — a user-authored crew name that routinely embeds real
  # people ("Dave & Mike's Catan Night"). A bare column-name allowlist can't tell
  # the two apart, so `name` masks for a plain admin like any other free text; a
  # game title is one superadmin (or dedicated Games panel) away.
  @always_safe_columns ~w(
    id slug username role status kind type action target_type
    visibility verdict error_kind stage llm_provider llm_model provider model voice
  )

  defp redact_sensitive(rows, _columns, true = _superadmin?), do: rows

  defp redact_sensitive(rows, columns, _superadmin?) do
    masked_cols =
      for {col, type} <- columns,
          type in @masked_types,
          col not in @always_safe_columns,
          do: col

    case masked_cols do
      [] ->
        rows

      cols ->
        Enum.map(rows, fn row ->
          Enum.reduce(cols, row, fn col, acc ->
            if Map.has_key?(acc, col) and not is_nil(Map.get(acc, col)),
              do: Map.put(acc, col, @redaction_marker),
              else: acc
          end)
        end)
    end
  end

  # ── Helpers ──

  defp safe(str) do
    ~s("#{String.replace(str, "\"", "\"\"")}")
  end

  defp parse_for_db(nil, _type), do: nil
  defp parse_for_db("", _type), do: nil

  defp parse_for_db(val, type) when type in ~w(integer bigint smallint) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_for_db(val, "boolean") do
    val == "true" or val == true
  end

  defp parse_for_db(val, "numeric") do
    case Float.parse(val) do
      {f, ""} -> Decimal.new(f)
      _ -> nil
    end
  end

  defp parse_for_db(val, _), do: val

  defp format(nil), do: "—"

  defp format(val) when is_binary(val) do
    if String.length(val) > 80 do
      String.slice(val, 0, 77) <> "..."
    else
      val
    end
  end

  defp format(val), do: to_string(val)

  defp input_type("boolean"), do: "checkbox"
  defp input_type(type) when type in ~w(integer bigint smallint numeric real double), do: "number"
  defp input_type(_), do: "text"

  defp row_identity(row, pk_col) do
    to_string(Map.get(row, pk_col))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="margin:0;padding:0 0.2rem;width:100vw;position:relative;left:50%;right:50%;margin-left:-50vw;margin-right:-50vw">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">DB Admin</h1>

      <div style="display:flex;gap:0.25rem;margin-bottom:0.5rem;flex-wrap:wrap">
        <%= for t <- @tables do %>
          <a
            href={"/admin/db?table=#{t}"}
            style={"padding:0.25rem 0.5rem;border-radius:0.3rem;font-size:0.7rem;font-weight:600;text-decoration:none;#{
              if @table_name == t,
                do: "background:var(--accent);color:var(--accent-text,#fff)",
                else: "background:var(--bg-subtle);color:var(--text);border:1px solid var(--border)"
            }"}
          >
            {t}
          </a>
        <% end %>
      </div>

      <%= if @table_name do %>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:0.3rem;gap:0.4rem">
          <p style="font-size:0.7rem;color:var(--text-muted);margin:0">
            {length(@rows)} rows in <code style="font-size:0.75rem">{@table_name}</code>
            <span :if={length(@rows) == @row_limit} title={"Browse is capped at #{@row_limit} rows"}>
              (newest {@row_limit}; capped)
            </span>
          </p>
          <div style="display:flex;gap:0.35rem;align-items:center">
            <button
              type="button"
              phx-click="toggle_view"
              class="btn-xs"
              style="white-space:nowrap"
            >
              {if @view_mode == :table, do: "☰ Extended", else: "⊞ Table"}
            </button>
            <span
              :if={not writable?(@table_name, @current_user)}
              title="audit_logs, schema_migrations and oban_* are read-only"
              style="font-size:0.7rem;font-weight:700;color:var(--text-muted);border:1px solid var(--border);border-radius:0.3rem;padding:0.25rem 0.5rem"
            >🔒 Read-only</span>
            <button
              :if={writable?(@table_name, @current_user)}
              type="button"
              phx-click="new_row"
              class="btn-primary btn-xs"
            >
              + New
            </button>
          </div>
        </div>

        <%!-- Form --%>
        <%= if @mode do %>
          <div style="background:var(--bg);border:2px solid var(--accent);border-radius:0.5rem;padding:1rem;margin-bottom:1rem">
            <h3 style="font-size:0.85rem;font-weight:600;margin:0 0 0.75rem">
              {if @mode == :new,
                do: "Insert into #{@table_name}",
                else: "Update #{@table_name} #{@pk_col}=#{@editing_id}"}
            </h3>
            <div
              phx-change="form_change"
              style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:0.5rem"
            >
              <%= for {col, type} <- @columns, col != @pk_col || @mode == :edit do %>
                <% disabled = col == @pk_col %>
                <div>
                  <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">
                    {col} <span style="font-weight:400;opacity:0.6">({type})</span>
                  </label>
                  <%= if type == "text" or String.contains?(type, "char") && String.length(Map.get(@form_data, col, "") |> to_string) > 30 do %>
                    <textarea
                      name={col}
                      value={Map.get(@form_data, col, "") |> to_string}
                      phx-value-field={col}
                      disabled={disabled}
                      rows="3"
                      style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text);resize:vertical"
                    />
                  <% else %>
                    <input
                      type={input_type(type)}
                      name={col}
                      value={Map.get(@form_data, col, "") |> to_string}
                      phx-value-field={col}
                      disabled={disabled}
                      style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text)"
                    />
                  <% end %>
                </div>
              <% end %>
            </div>
            <p
              :if={Map.get(@form_errors, :base)}
              style="margin:0.6rem 0 0;font-size:0.75rem;color:var(--red);white-space:pre-wrap"
            >
              {Map.get(@form_errors, :base)}
            </p>
            <div style="display:flex;gap:0.5rem;margin-top:0.75rem">
              <button
                type="button"
                phx-click="save"
                class="btn-primary btn-xs"
              >Save</button>
              <button
                type="button"
                phx-click="cancel_form"
                class="btn-xs"
              >Cancel</button>
            </div>
          </div>
        <% end %>

        <%!-- Table view --%>
        <%= if @view_mode == :table do %>
          <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
            <table style="width:100%;border-collapse:collapse;font-size:0.75rem;table-layout:auto">
              <thead>
                <tr style="background:var(--bg-subtle);text-align:left">
                  <%= for {col, type} <- @columns do %>
                    <th
                      style="padding:0.2rem 0.3rem;border-bottom:1px solid var(--border);white-space:nowrap"
                      title={type}
                    >
                      {col}
                    </th>
                  <% end %>
                  <th style="padding:0.2rem 0.3rem;border-bottom:1px solid var(--border);white-space:nowrap;width:110px">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= for row <- @rows do %>
                  <% row_id = row_identity(row, @pk_col) %>
                  <tr style="background:var(--bg)">
                    <%= for {col, _type} <- @columns do %>
                      <td
                        style="padding:0.15rem 0.3rem;border-bottom:1px solid var(--border-subtle);overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
                        title={format(Map.get(row, col))}
                      >
                        {format(Map.get(row, col))}
                      </td>
                    <% end %>
                    <td style="padding:0.15rem 0.3rem;border-bottom:1px solid var(--border-subtle);white-space:nowrap">
                      <span
                        :if={not writable?(@table_name, @current_user)}
                        style="color:var(--text-muted)"
                      >—</span>
                      <div
                        :if={writable?(@table_name, @current_user)}
                        style="display:flex;gap:0.2rem;align-items:center"
                      >
                        <button
                          type="button"
                          phx-click="edit_row"
                          phx-value-id={row_id}
                          class="btn-xs"
                        >Edit</button>
                        <%= if @delete_id == row_id do %>
                          <span style="color:var(--red);font-size:0.72rem">Delete?</span>
                          <button
                            type="button"
                            phx-click="delete_row"
                            phx-value-id={row_id}
                            class="btn-danger-outline btn-xs"
                          >Yes</button>
                          <button
                            type="button"
                            phx-click="cancel_delete"
                            class="btn-xs"
                          >No</button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="confirm_delete"
                            phx-value-id={row_id}
                            class="btn-icon btn-xs"
                            title="Delete"
                          >✕</button>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <%!-- Extended view --%>
        <% else %>
          <div style="display:flex;flex-direction:column;gap:0.25rem">
            <%= for {row, row_idx} <- Enum.with_index(@rows) do %>
              <% row_id = row_identity(row, @pk_col) %>
              <div style={"background:var(--bg);border:1px solid var(--border);border-radius:0.375rem;padding:0.4rem 0.5rem;#{
                if rem(row_idx, 2) == 0, do: "", else: "background:var(--bg-subtle);"
              }"}>
                <div style="display:grid;grid-template-columns:auto 1fr;gap:0.05rem 0.6rem;font-size:0.72rem;align-items:start">
                  <%= for {col, type} <- @columns do %>
                    <div
                      style="font-weight:600;color:var(--text-muted);white-space:nowrap;padding:0.1rem 0"
                      title={type}
                    >
                      {col}
                    </div>
                    <div style="padding:0.1rem 0;word-break:break-word;white-space:pre-wrap;overflow-wrap:anywhere">
                      {format(Map.get(row, col))}
                    </div>
                  <% end %>
                </div>
                <div
                  :if={writable?(@table_name, @current_user)}
                  style="display:flex;gap:0.25rem;margin-top:0.3rem;padding-top:0.3rem;border-top:1px solid var(--border-subtle)"
                >
                  <button
                    type="button"
                    phx-click="edit_row"
                    phx-value-id={row_id}
                    class="btn-xs"
                  >Edit</button>
                  <%= if @delete_id == row_id do %>
                    <span style="color:var(--red);font-size:0.75rem">Delete?</span>
                    <button
                      type="button"
                      phx-click="delete_row"
                      phx-value-id={row_id}
                      class="btn-danger-outline btn-xs"
                    >Yes</button>
                    <button
                      type="button"
                      phx-click="cancel_delete"
                      class="btn-xs"
                    >No</button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={row_id}
                      class="btn-icon btn-xs"
                    >✕</button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      <% else %>
        <p style="color:var(--text-muted);font-size:0.85rem">
          Select a table above to browse, create, edit, or delete rows.
        </p>
      <% end %>
    </div>
    """
  end
end
