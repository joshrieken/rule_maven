defmodule RuleMavenWeb.AdminLive do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Repo, Users, Games, Faq}
  alias Ecto.Adapters.SQL

  @impl true
  def mount(_params, _session, socket) do
    if Users.game_master?(socket.assigns.current_user) do
      tables = fetch_tables()
      threads = Games.all_question_threads()

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
         page: 1,
         per_page: 50,
         threads: threads,
         section: nil,
         merge_question: "",
         merge_answer: "",
         merge_thread_root: nil
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
        rows = fetch_rows(table, columns)

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
    {:noreply, push_patch(socket, to: ~p"/admin?table=#{t}")}
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

    SQL.query!(Repo, "DELETE FROM #{safe(table)} WHERE #{safe(pk)} = $1", [id])

    rows = fetch_rows(table, socket.assigns.columns)
    {:noreply, assign(socket, rows: rows, delete_id: nil)}
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
    row = fetch_row(table, pk, id, socket.assigns.columns)

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

  # Thread consolidation
  def handle_event("show_section", %{"section" => section}, socket) do
    threads =
      if section == "threads", do: Games.all_question_threads(), else: socket.assigns.threads

    {:noreply,
     assign(socket,
       section: section,
       threads: threads,
       merge_thread_root: nil,
       merge_question: "",
       merge_answer: ""
     )}
  end

  def handle_event("prepare_merge", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    thread = Enum.find(socket.assigns.threads, &(&1.root.id == id))

    if thread do
      followups = thread.followups
      answer = Faq.build_consolidated_answer(thread.root, followups)

      {:noreply,
       assign(socket,
         merge_thread_root: thread,
         merge_question: thread.root.question,
         merge_answer: answer
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_merge", _params, socket) do
    {:noreply, assign(socket, merge_thread_root: nil, merge_question: "", merge_answer: "")}
  end

  def handle_event("merge_form_change", params, socket) do
    socket =
      cond do
        Map.has_key?(params, "merge_question") ->
          assign(socket, merge_question: params["merge_question"])

        Map.has_key?(params, "merge_answer") ->
          assign(socket, merge_answer: params["merge_answer"])

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("merge_thread", _params, socket) do
    thread = socket.assigns.merge_thread_root

    case Faq.consolidate_thread(thread.root, thread.followups, %{
           question: socket.assigns.merge_question,
           answer: socket.assigns.merge_answer
         }) do
      {:ok, _faq} ->
        threads = Games.all_question_threads()

        {:noreply,
         assign(socket,
           threads: threads,
           merge_thread_root: nil,
           merge_question: "",
           merge_answer: ""
         )
         |> put_flash(:info, "Thread consolidated into FAQ!")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create FAQ entry.")}
    end
  end

  # Save
  def handle_event("save", _params, socket) do
    table = socket.assigns.table_name
    pk = socket.assigns.pk_col
    columns = socket.assigns.columns
    mode = socket.assigns.mode
    data = socket.assigns.form_data
    cols_map = Map.new(columns)

    # Exclude pk from insert/update
    set_cols = Enum.filter(Map.keys(cols_map), &(&1 != pk))
    vals = Enum.map(set_cols, &parse_for_db(Map.get(data, &1), cols_map[&1]))

    case mode do
      :new ->
        placeholders =
          Enum.map_join(set_cols, ", ", &"$#{Enum.find_index(set_cols, fn c -> c == &1 end) + 1}")

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

    rows = fetch_rows(table, columns)

    {:noreply,
     assign(socket, rows: rows, mode: nil, editing_id: nil, form_data: %{}, form_errors: %{})}
  end

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

  defp fetch_rows(table, columns) do
    cols = Enum.map_join(columns, ", ", fn {c, _} -> safe(c) end)

    %{rows: rows, columns: col_names} =
      SQL.query!(
        Repo,
        "SELECT #{cols} FROM #{safe(table)} ORDER BY 1 DESC LIMIT 500",
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
      <.link navigate={~p"/"} style="color:var(--blue);font-size:0.75rem">&larr; Back to games</.link>

      <h1 style="font-size:1.3rem;font-weight:700;margin:0.3rem 0">Admin — Database</h1>

      <div style="display:flex;gap:0.5rem;margin-bottom:0.5rem;align-items:center">
        <.link
          href="/oban"
          target="_blank"
          style="color:var(--accent);font-size:0.75rem;font-weight:600;text-decoration:none"
        >Oban Dashboard ↗</.link>
        <.link
          href="/settings"
          style="color:var(--blue);font-size:0.75rem;text-decoration:none"
        >Settings</.link>
        <.link
          href="/settings/usage"
          style="color:var(--blue);font-size:0.75rem;text-decoration:none"
        >LLM Usage</.link>
        <button
          type="button"
          phx-click="show_section"
          phx-value-section="threads"
          style={"background:none;border:1px solid var(--border);border-radius:0.3rem;padding:0.2rem 0.5rem;font-size:0.65rem;font-weight:600;cursor:pointer;#{if @section == "threads", do: "background:var(--accent);color:#fff;border-color:var(--accent)", else: "color:var(--text-muted)"}"}
        >Review Threads</button>
        <button
          type="button"
          phx-click="show_section"
          phx-value-section=""
          style={"background:none;border:1px solid var(--border);border-radius:0.3rem;padding:0.2rem 0.5rem;font-size:0.65rem;font-weight:600;cursor:pointer;#{if @section == nil, do: "background:var(--accent);color:#fff;border-color:var(--accent)", else: "color:var(--text-muted)"}"}
        >DB Tables</button>
      </div>

      <div style="display:flex;gap:0.25rem;margin-bottom:0.5rem;flex-wrap:wrap">
        <%= for t <- @tables do %>
          <a
            href={"/admin?table=#{t}"}
            style={"padding:0.25rem 0.5rem;border-radius:0.3rem;font-size:0.7rem;font-weight:600;text-decoration:none;#{
              if @table_name == t,
                do: "background:var(--accent);color:#fff",
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
          </p>
          <div style="display:flex;gap:0.35rem;align-items:center">
            <button
              type="button"
              phx-click="toggle_view"
              style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.3rem 0.65rem;border-radius:0.375rem;font-size:0.7rem;font-weight:600;cursor:pointer;white-space:nowrap"
            >
              {if @view_mode == :table, do: "☰ Extended", else: "⊞ Table"}
            </button>
            <button
              type="button"
              phx-click="new_row"
              style="background:var(--accent);color:#fff;border:none;padding:0.3rem 0.75rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer"
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
            <div style="display:flex;gap:0.5rem;margin-top:0.75rem">
              <button
                type="button"
                phx-click="save"
                style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer"
              >Save</button>
              <button
                type="button"
                phx-click="cancel_form"
                style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;cursor:pointer"
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
                      <div style="display:flex;gap:0.2rem;align-items:center">
                        <button
                          type="button"
                          phx-click="edit_row"
                          phx-value-id={row_id}
                          style="color:var(--text-secondary);background:none;border:none;font-size:0.72rem;cursor:pointer"
                        >Edit</button>
                        <%= if @delete_id == row_id do %>
                          <span style="color:var(--red);font-size:0.72rem">Delete?</span>
                          <button
                            type="button"
                            phx-click="delete_row"
                            phx-value-id={row_id}
                            style="color:var(--red);background:none;border:none;font-size:0.72rem;font-weight:600;cursor:pointer"
                          >Yes</button>
                          <button
                            type="button"
                            phx-click="cancel_delete"
                            style="color:var(--text-muted);background:none;border:none;font-size:0.72rem;cursor:pointer"
                          >No</button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="confirm_delete"
                            phx-value-id={row_id}
                            style="color:var(--text-muted);background:none;border:none;font-size:0.72rem;cursor:pointer"
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

          <%!-- Extended view (like \x on) --%>
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
                <div style="display:flex;gap:0.25rem;margin-top:0.3rem;padding-top:0.3rem;border-top:1px solid var(--border-subtle)">
                  <button
                    type="button"
                    phx-click="edit_row"
                    phx-value-id={row_id}
                    style="color:var(--blue);background:none;border:none;font-size:0.75rem;cursor:pointer;font-weight:600"
                  >Edit</button>
                  <%= if @delete_id == row_id do %>
                    <span style="color:var(--red);font-size:0.75rem">Delete?</span>
                    <button
                      type="button"
                      phx-click="delete_row"
                      phx-value-id={row_id}
                      style="color:var(--red);background:none;border:none;font-size:0.75rem;font-weight:600;cursor:pointer"
                    >Yes</button>
                    <button
                      type="button"
                      phx-click="cancel_delete"
                      style="color:var(--text-muted);background:none;border:none;font-size:0.75rem;cursor:pointer"
                    >No</button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="confirm_delete"
                      phx-value-id={row_id}
                      style="color:var(--text-muted);background:none;border:none;font-size:0.75rem;cursor:pointer"
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

      <%!-- Thread consolidation --%>
      <%= if @section == "threads" do %>
        <div style="margin-top:1rem">
          <h2 style="font-size:1rem;font-weight:700;margin:0 0 0.5rem">
            Question Threads ({length(@threads)})
          </h2>
          <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
            Review root questions with their followups. Merge into FAQ entries.
          </p>

          <!-- Merge form -->
          <%= if @merge_thread_root do %>
            <div style="background:var(--bg);border:2px solid var(--accent);border-radius:0.5rem;padding:1rem;margin-bottom:1rem">
              <h3 style="font-size:0.85rem;font-weight:600;margin:0 0 0.75rem">
                Merge Thread into FAQ
              </h3>
              <div style="display:flex;flex-direction:column;gap:0.5rem">
                <div>
                  <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Question</label>
                  <textarea
                    name="merge_question"
                    phx-change="merge_form_change"
                    rows="2"
                    style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text);resize:vertical"
                  ><%= @merge_question %></textarea>
                </div>
                <div>
                  <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Answer (markdown)</label>
                  <textarea
                    name="merge_answer"
                    phx-change="merge_form_change"
                    rows="6"
                    style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg);color:var(--text);resize:vertical"
                  ><%= @merge_answer %></textarea>
                </div>
              </div>
              <div style="display:flex;gap:0.5rem;margin-top:0.75rem">
                <button
                  type="button"
                  phx-click="merge_thread"
                  style="background:var(--accent);color:#fff;border:none;padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;font-weight:600;cursor:pointer"
                >Publish to FAQ</button>
                <button
                  type="button"
                  phx-click="cancel_merge"
                  style="background:var(--bg-subtle);color:var(--text);border:1px solid var(--border);padding:0.35rem 1rem;border-radius:0.375rem;font-size:0.75rem;cursor:pointer"
                >Cancel</button>
              </div>
            </div>
          <% end %>

          <div style="display:flex;flex-direction:column;gap:0.5rem">
            <%= for thread <- @threads do %>
              <% root = thread.root %>
              <div style="background:var(--bg);border:1px solid var(--border);border-radius:0.375rem;padding:0.6rem 0.75rem">
                <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:0.5rem">
                  <div style="flex:1;min-width:0">
                    <div style="font-weight:600;font-size:0.8rem;color:var(--text);margin-bottom:0.25rem">
                      <span style="color:var(--text-muted);font-weight:400">[{root.game &&
                        root.game.name}]</span> {String.slice(root.question, 0, 100)}
                    </div>
                    <div style="font-size:0.72rem;color:var(--text-muted);line-height:1.4">
                      {String.slice(root.answer || "", 0, 150)}{if String.length(root.answer || "") >
                                                                     150, do: "…"}
                    </div>
                    <%= if thread.followups != [] do %>
                      <div style="margin-top:0.35rem;padding-left:0.5rem;border-left:2px solid var(--border-subtle)">
                        <div style="font-size:0.65rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">
                          {length(thread.followups)} followup(s)
                        </div>
                        <%= for f <- thread.followups do %>
                          <div style="font-size:0.65rem;color:var(--text-muted);margin-bottom:0.1rem">
                            ↳ {String.slice(f.question, 0, 80)} &rarr; {String.slice(
                              f.answer || "",
                              0,
                              60
                            )}
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                  <button
                    type="button"
                    phx-click="prepare_merge"
                    phx-value-id={root.id}
                    style="background:var(--accent);color:#fff;border:none;padding:0.25rem 0.6rem;border-radius:0.3rem;font-size:0.65rem;font-weight:600;cursor:pointer;white-space:nowrap;flex-shrink:0"
                  >Merge → FAQ</button>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @threads == [] do %>
            <p style="color:var(--text-muted);font-size:0.8rem;text-align:center;padding:1.5rem 0">
              No question threads with followups yet.
            </p>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
