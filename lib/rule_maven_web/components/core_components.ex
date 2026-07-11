defmodule RuleMavenWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: RuleMavenWeb.Gettext

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      data-flash
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "secondary" => "btn-secondary",
      nil => "btn-primary btn-soft"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div style="overflow-x:auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Thumbs-up vote button: icon and tally share one hit target. Padding plus a
  matching negative margin enlarge the clickable area without shifting the
  surrounding layout.
  """
  attr :event, :string, required: true
  attr :id, :any, required: true
  attr :voted, :boolean, required: true
  attr :count, :integer, required: true
  attr :title, :string, required: true

  def vote_thumb(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-id={@id}
      phx-value-vote="up"
      style={"background:none;border:none;padding:0.4rem;margin:-0.4rem;line-height:1;cursor:pointer;display:inline-flex;align-items:center;gap:0.15rem;color:#{if @voted, do: "var(--accent)", else: "var(--text-muted)"}"}
      title={@title}
    >
      <.icon
        name={if @voted, do: "hero-hand-thumb-up-solid", else: "hero-hand-thumb-up"}
        class="size-4"
      />
      <span style="font-size:0.65rem;color:var(--text-muted)" title="Total helpful votes">{@count}</span>
    </button>
    """
  end

  @doc """
  Role badge: "A" for an admin, "SA" for a super admin. Renders nothing for an
  ordinary user, so it can be dropped in anywhere a username appears.

  The letters are deliberately terse — this sits inline beside a username in a
  header that already stacks on mobile — so the full role name lives in `title`
  and in the screen-reader label rather than in the visible glyphs.

  Capability-driven, never a role-name comparison: see `Users.can?/2`.
  """
  attr :user, :any, required: true

  def role_badge(assigns) do
    ~H"""
    <span
      :if={RuleMaven.Users.can?(@user, :admin)}
      class={[
        "role-badge",
        RuleMaven.Users.can?(@user, :superadmin) && "role-badge--super"
      ]}
      title={role_badge_label(@user)}
      aria-label={role_badge_label(@user)}
    >
      {if RuleMaven.Users.can?(@user, :superadmin), do: "SA", else: "A"}
    </span>
    """
  end

  defp role_badge_label(user) do
    if RuleMaven.Users.can?(user, :superadmin), do: "Super admin", else: "Admin"
  end

  @doc """
  Difficulty badge: BGG community complexity ("weight", 1.0-5.0) shown as a
  number plus bucket label, e.g. "2.3 · Medium-Light". Renders nothing when
  weight is nil (unrated / not yet backfilled) — no fallback text.
  """
  attr :weight, :float, default: nil

  def difficulty_badge(assigns) do
    ~H"""
    <span
      :if={@weight}
      class="difficulty-badge"
      style={"--difficulty-color:#{elem(difficulty_bucket(@weight), 1)}"}
      title={"Complexity #{format_weight(@weight)} / 5 (BGG community rating)"}
    >
      <strong>{format_weight(@weight)}</strong> {elem(difficulty_bucket(@weight), 0)}
    </span>
    """
  end

  @doc """
  Buckets a BGG weight (1.0-5.0) into `{label, css_color}` using BGG's own
  category names. Returns nil for nil weight.
  """
  def difficulty_bucket(nil), do: nil

  def difficulty_bucket(weight) do
    cond do
      weight < 1.5 -> {"Light", "var(--green)"}
      weight < 2.5 -> {"Medium-Light", "var(--blue)"}
      weight < 3.5 -> {"Medium", "var(--yellow)"}
      weight < 4.5 -> {"Medium-Heavy", "var(--orange, var(--yellow))"}
      true -> {"Heavy", "var(--red)"}
    end
  end

  defp format_weight(weight), do: :erlang.float_to_binary(weight / 1, decimals: 1)

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(RuleMavenWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RuleMavenWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Rulebook citation cards for an answered question: a source · page header over
  the quoted passage. Prefers the multi-citation `citations` field, falling back
  to the legacy scalar `cited_*` fields for rows saved before that column
  existed. Quotes sharing a {page, source} merge into one card (joined with an
  ellipsis) and cards sort by page ascending, pageless last — mirroring the
  chat view's citation grouping.
  """
  attr :q, :map, required: true, doc: "question-log row (or map) with citation fields"

  def citation_cards(assigns) do
    assigns = assign(assigns, :citations, grouped_citations(assigns.q))

    ~H"""
    <figure
      :for={c <- @citations}
      style="margin:0.7rem 0 0;border-radius:0.6rem;overflow:hidden;border:1px solid var(--border);background:var(--bg-subtle)"
    >
      <figcaption style="display:flex;align-items:center;gap:0.4rem;padding:0.4rem 0.7rem;font-size:0.72rem;border-bottom:1px solid var(--border-subtle);color:var(--text-secondary)">
        <span aria-hidden="true" style="opacity:0.7">&#128214;</span>
        <%!-- Page sits outside the truncating span: a long source name should
              ellipsis itself, never eat the page number. --%>
        <span style="font-weight:600;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
          {c["source"] || "Rulebook"}
        </span>
        <span :if={c["page"]} class="cite-page">p.{c["page"]}</span>
      </figcaption>
      <div style="padding:0.5rem 0.75rem 0.6rem 0.9rem;border-left:3px solid var(--accent)">
        <%!-- Content sits flush against the tags: `pre-line` turns the
              template's own indentation newlines into blank lines. --%>
        <blockquote
          :for={{parts, i} <- Enum.with_index(c["quotes"] || [])}
          style={"margin:0;#{if i > 0, do: "padding-top:0.5rem;margin-top:0.5rem;border-top:1px dashed var(--border-subtle);", else: ""}white-space:pre-line;font-size:0.82rem;line-height:1.6;word-break:break-word;color:var(--text)"}
        >
          <strong
            :if={parts.heading}
            style="display:block;font-size:0.85rem;margin-bottom:0.15rem;color:var(--text)"
          >{parts.heading}</strong>{parts.body}
        </blockquote>
      </div>
    </figure>
    """
  end

  @doc """
  Every page cited by a question, ascending, deduped, pageless citations
  dropped. Reads the same grouping the cards render from, so a summary chip
  can't disagree with the cards it summarizes.
  """
  def citation_pages(q) do
    q
    |> grouped_citations()
    |> Enum.map(& &1["page"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp grouped_citations(q) do
    case Map.get(q, :citations) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        if Map.get(q, :cited_passage) do
          [
            %{
              "quote" => Map.get(q, :cited_passage),
              "page" => Map.get(q, :cited_page),
              "source" => Map.get(q, :cited_source)
            }
          ]
        else
          []
        end
    end
    |> Enum.group_by(&{&1["page"], &1["source"]})
    |> Enum.map(fn {{page, source}, group} ->
      quotes =
        group
        |> Enum.map(&split_quote(&1["quote"]))
        |> Enum.reject(&(&1.heading == nil and &1.body == ""))

      %{"page" => page, "source" => source, "quotes" => quotes}
    end)
    |> Enum.sort_by(fn %{"page" => page} -> {page == nil, page} end)
  end

  # Splits a cited passage into an optional leading heading and the body. Rulebook
  # passages often carry a section heading on its own line ("Round Two",
  # "1. Resource Production") that would otherwise smush into the paragraph once
  # newlines collapse. Runs of blank lines are squeezed to a single break so the
  # `pre-line` render stays tight.
  defp split_quote(quote) when is_binary(quote) do
    cleaned =
      quote
      |> RuleMaven.Text.scrub_decorative()
      |> String.replace(~r/\n[ \t]*\n[ \t\n]*/, "\n")
      |> String.trim()

    case String.split(cleaned, "\n", parts: 2) do
      [first, rest] ->
        if heading_line?(first),
          do: %{heading: first, body: String.trim_leading(rest)},
          else: split_inline_heading(cleaned)

      _ ->
        split_inline_heading(cleaned)
    end
  end

  defp split_quote(_), do: %{heading: nil, body: ""}

  # Many stored passages glue a section heading straight onto the body with no
  # newline ("Round Two Once all players…"). Only pull off a leading run we're
  # confident is a structural heading — a spelled-out round or a
  # keyword+number head — so we never chop a real sentence in half.
  @inline_heading ~r/^(Round (?:One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)|(?:Phase|Step|Turn|Stage|Round) \d+)\b[ ]+(?=[A-Z])/

  defp split_inline_heading(text) do
    case Regex.run(@inline_heading, text, return: :index) do
      [{0, len} | _] ->
        heading = text |> binary_part(0, len) |> String.trim()
        body = text |> binary_part(len, byte_size(text) - len) |> String.trim()
        if body == "", do: %{heading: nil, body: text}, else: %{heading: heading, body: body}

      _ ->
        %{heading: nil, body: text}
    end
  end

  # A short opening line with no sentence-ending punctuation reads as a heading:
  # a section title ("Setup"), a numbered/lettered head ("1. Resource
  # Production"), or a spelled-out round ("Round Two"). Guards against treating a
  # normal wrapped sentence as a heading.
  defp heading_line?(line) do
    trimmed = String.trim(line)

    String.length(trimmed) in 1..48 and
      not String.match?(trimmed, ~r/[.!?:,;]$/) and
      length(String.split(trimmed, " ")) <= 6
  end
end
