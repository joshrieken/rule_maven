defmodule RuleMavenWeb.GameLive.Community do
  @moduledoc """
  Community Q&A browse page (formerly the FAQ page). Three disjoint tabs:

    * **Verified** — admin-verified community answers.
    * **Community** — crowd-promoted answers awaiting admin sign-off.
    * **Unverified** — answered, pool-shared questions from other players that
      haven't reached community status yet. Browsing these is the discovery
      surface that feeds promotion quorum: upvotes here both count toward
      promotion and add the question to the voter's own list.

  A non-empty search always runs across **all** tabs at once; results carry a
  status badge instead of relying on the selected tab.
  """
  use RuleMavenWeb, :live_view

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMavenWeb.GameLive.{SubBar, ToolHost, ToolPanel}
  alias RuleMavenWeb.ReportModal

  # Table-tool events (sub-bar Play/Learn, window chrome) are shared with the
  # game page via ToolHost.
  @tool_events RuleMavenWeb.GameLive.ToolHost.events()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game_by_token(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "That game doesn’t exist.") |> push_navigate(to: ~p"/")}

      game ->
        mount_game(game, socket)
    end
  end

  defp mount_game(game, socket) do
    categories = Games.list_game_categories(game)

    socket =
      assign(socket,
        game: game,
        categories: categories,
        # Report-reason modal: nil, or the question id being reported.
        report_target: nil,
        filter_category: nil,
        search_query: "",
        # nil until handle_params: defaults to the first non-empty tab unless
        # the URL names one (explicit switches patch ?tab= so they stick).
        tab: nil,
        # Question ids whose full answer is expanded inline on the card.
        expanded: MapSet.new(),
        page_title: "Community Q&A — #{game.name}"
      )

    socket = ToolHost.mount_header(socket, game)
    socket = ToolHost.mount_tools(socket, game)

    {:ok, load_questions(socket)}
  end

  defp load_questions(socket) do
    game = socket.assigns.game
    user_id = socket.assigns.current_user.id

    community_all = Games.faq_questions(game)
    {verified, community} = Enum.split_with(community_all, & &1.verified)

    community_texts =
      MapSet.new(community_all, &String.downcase(QuestionLog.display_question(&1)))

    # Drop unverified rows that duplicate a community question's text — the
    # promoted copy is the one that should surface.
    unverified =
      game
      |> Games.unverified_pool_questions()
      |> Enum.reject(fn q ->
        MapSet.member?(community_texts, String.downcase(QuestionLog.display_question(q)))
      end)

    question_ids = Enum.map(community_all ++ unverified, & &1.id)
    favorited_ids = Games.favorited_answer_ids(user_id, question_ids)

    {vote_counts, user_votes, asker_confirmed} =
      Games.community_vote_maps(question_ids, user_id)

    assign(socket,
      verified_questions: sort_favorited_first(verified, favorited_ids),
      community_questions: sort_favorited_first(community, favorited_ids),
      unverified_questions: unverified,
      favorited_ids: favorited_ids,
      vote_counts: vote_counts,
      user_votes: user_votes,
      asker_confirmed: asker_confirmed,
      category_map: Games.categories_for_questions(question_ids),
      flagged_ids: Games.user_flagged_ids(user_id)
    )
  end

  # Only vote tallies changed — skip the heavier question/category reload.
  defp reload_votes(socket) do
    question_ids =
      Enum.map(
        socket.assigns.verified_questions ++
          socket.assigns.community_questions ++ socket.assigns.unverified_questions,
        & &1.id
      )

    {vote_counts, user_votes, asker_confirmed} =
      Games.community_vote_maps(question_ids, socket.assigns.current_user.id)

    assign(socket,
      vote_counts: vote_counts,
      user_votes: user_votes,
      asker_confirmed: asker_confirmed
    )
  end

  # First non-empty tab, left to right (matching the button order);
  # "community" when everything is empty.
  defp default_tab(socket) do
    [
      {"verified", socket.assigns.verified_questions},
      {"community", socket.assigns.community_questions},
      {"unverified", socket.assigns.unverified_questions}
    ]
    |> Enum.find_value("community", fn {tab, qs} -> qs != [] && tab end)
  end

  defp all_questions(socket) do
    socket.assigns.verified_questions ++
      socket.assigns.community_questions ++ socket.assigns.unverified_questions
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        t when t in ["verified", "community", "unverified"] -> t
        _ -> socket.assigns.tab || default_tab(socket)
      end

    filter_category =
      with cat when is_binary(cat) <- params["category"],
           {:ok, id} <- RuleMaven.Hashid.decode(cat) do
        id
      else
        _ -> nil
      end

    {:noreply, assign(socket, tab: tab, filter_category: filter_category)}
  end

  @impl true
  def handle_event(event, params, socket) when event in @tool_events,
    do: ToolHost.handle_tool_event(event, params, socket)

  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["verified", "community", "unverified"] do
    # Patch ?tab= so the explicit choice survives refresh/back; also drops any
    # ?category= param (handle_params resets filter_category).
    {:noreply, push_patch(socket, to: ~p"/games/#{socket.assigns.game}/community?tab=#{tab}")}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, search_query: query)}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "")}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str) do
      expanded = socket.assigns.expanded

      expanded =
        if MapSet.member?(expanded, id),
          do: MapSet.delete(expanded, id),
          else: MapSet.put(expanded, id)

      {:noreply, assign(socket, expanded: expanded)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("vote", %{"id" => id_str}, socket) do
    uid = socket.assigns.current_user.id

    with {id, ""} <- Integer.parse(id_str),
         # Scope to rows this page rendered, so a forged id can't be voted here.
         true <- Enum.any?(all_questions(socket), &(&1.id == id)) do
      case Games.set_community_vote(id, uid, "up", socket.assigns.is_admin) do
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, vote_error_message(reason))}

        _ ->
          {:noreply, reload_votes(socket)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_category", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {cat_id, ""} ->
        socket =
          if socket.assigns.filter_category == cat_id do
            assign(socket, filter_category: nil)
          else
            assign(socket, filter_category: cat_id)
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reject", %{"id" => id_str}, socket) do
    if socket.assigns.is_admin do
      if q = Games.get_game_question(socket.assigns.game, id_str) do
        Games.set_question_visibility(q.id, "private")
      end
    end

    {:noreply, load_questions(socket)}
  end

  @impl true
  def handle_event("favorite_community_answer", %{"id" => id_str}, socket) do
    with {id, ""} <- Integer.parse(id_str),
         {:ok, _favorited?} <-
           Games.toggle_answer_favorite(socket.assigns.current_user.id, id) do
      {:noreply, load_questions(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Opens the report-reason modal; the flag is written on "submit_report".
  @impl true
  def handle_event("report_answer", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    # Scope to this game so a forged id from another game can't be flagged here.
    if Enum.any?(all_questions(socket), &(&1.id == id)) do
      {:noreply, assign(socket, report_target: id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, report_target: nil)}

  @impl true
  def handle_event("submit_report", params, socket) do
    case socket.assigns.report_target do
      nil ->
        {:noreply, socket}

      id ->
        socket = assign(socket, report_target: nil)

        case Games.report_answer(
               id,
               socket.assigns.current_user,
               ReportModal.compose_reason(params)
             ) do
          {:ok, %{pulled: pulled}} ->
            socket =
              socket
              |> assign(flagged_ids: MapSet.put(socket.assigns.flagged_ids, id))
              |> put_flash(:info, report_flash(pulled))

            {:noreply, load_questions(socket)}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  @impl true
  def handle_event("pull_for_review", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    user = socket.assigns.current_user

    # Scope to this game so a forged id from another game can't be pulled here.
    if Enum.any?(all_questions(socket), &(&1.id == id)) do
      case Games.pull_for_review(id, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Pulled from the Community Q&A — it's in the moderation queue.")
           |> load_questions()}

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp report_flash(true), do: "Reported and pulled from the Community Q&A for review. Thanks!"
  defp report_flash(false), do: "Reported — thanks. A moderator will take a look."

  defp vote_error_message(:self_vote), do: "You can't downvote your own answer."
  defp vote_error_message(:not_votable), do: "This answer isn't open for voting."

  defp vote_error_message(:settled),
    do: "This answer has been settled — its votes are final."

  defp vote_error_message(_), do: "Couldn't record your vote."

  # Favorited questions float to the top within whatever list they're
  # rendered in (a category bucket, the untagged group, …); Enum.sort_by is
  # stable, so ties keep their original (query-ranked) order.
  defp sort_favorited_first(questions, favorited_ids) do
    Enum.sort_by(questions, fn q -> if MapSet.member?(favorited_ids, q.id), do: 0, else: 1 end)
  end

  defp questions_for_category(questions, category_map, cat_id) do
    Enum.filter(questions, fn q ->
      cats = Map.get(category_map, q.id, [])
      Enum.any?(cats, &(&1.id == cat_id))
    end)
  end

  defp untagged_questions(questions, category_map) do
    Enum.filter(questions, fn q ->
      Map.get(category_map, q.id, []) == []
    end)
  end

  # Categories that tag at least one of the given (currently shown) questions.
  # Keeps a pill off the bar unless clicking it would surface something, so the
  # filter never lands on an empty "No questions in this category yet" view.
  defp categories_with_questions(categories, questions, category_map) do
    present =
      questions
      |> Enum.flat_map(fn q -> Map.get(category_map, q.id, []) end)
      |> MapSet.new(& &1.id)

    Enum.filter(categories, &MapSet.member?(present, &1.id))
  end

  defp matches_search?(_q, ""), do: true

  defp matches_search?(q, query) do
    needle = String.downcase(query)

    # listed_question, not display_question: the card renders the withheld form,
    # so searching the raw column would let a stranger probe for text that is
    # never displayed to them.
    haystack =
      String.downcase(
        QuestionLog.listed_question(q) <> " " <> (q.canonical_answer || q.answer || "")
      )

    String.contains?(haystack, needle)
  end

  # Universal search: every tab at once, tagged with the tab it came from so
  # the card can show a status badge.
  defp search_results(assigns) do
    query = assigns.search_query

    Enum.filter(
      Enum.map(assigns.verified_questions, &{&1, "verified"}) ++
        Enum.map(assigns.community_questions, &{&1, "community"}) ++
        Enum.map(assigns.unverified_questions, &{&1, "unverified"}),
      fn {q, _status} -> matches_search?(q, query) end
    )
  end

  defp tab_questions(assigns) do
    case assigns.tab do
      "verified" -> assigns.verified_questions
      "unverified" -> assigns.unverified_questions
      _ -> assigns.community_questions
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
    <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game.image_url} />
    <%!-- Report-reason modal: pick why the answer is being reported. --%>
    <ReportModal.report_modal :if={@report_target} />
    <%!-- Same tool sub-bar as the game page: every game screen keeps the
          table tools one tap away. Admin Review lives in the More menu. --%>
    <SubBar.game_bar
      game={@game}
      sources={@sources}
      community_count={@community_count}
      is_admin={@is_admin}
      current_user={@current_user}
      has_cheatsheet={@has_cheatsheet}
      current={:community}
      expansions={@expansions}
      included_expansions={@included_expansions}
      house_rule_count={@house_rule_count}
    />
    <div style="max-width:52rem;margin:0 auto;padding:1.5rem 1rem;position:relative;z-index:1">
      <h1 style="font-size:1.25rem;font-weight:700;margin-bottom:0.25rem">
        {@game.name} — Community Q&amp;A
      </h1>
      <p style="font-size:0.75rem;color:var(--text-secondary);margin-bottom:1rem">
        Questions players have asked, with answers drawn from the rulebook.
      </p>

      <%!-- Search across all tabs at once --%>
      <form id="community-search" phx-change="search" phx-submit="search" style="margin-bottom:0.9rem">
        <div style="display:flex;align-items:center;gap:0.4rem">
          <input
            type="text"
            name="q"
            value={@search_query}
            placeholder="Search all questions &amp; answers…"
            phx-debounce="200"
            autocomplete="off"
            style="flex:1;font-size:0.78rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.4rem;background:var(--bg-surface);color:var(--text)"
          />
          <button
            :if={@search_query != ""}
            type="button"
            phx-click="clear_search"
            class="btn-xs"
          >
            Clear ✕
          </button>
        </div>
      </form>

      <%= if @search_query != "" do %>
        <%!-- Universal search results: all tabs, status-badged --%>
        <% results = search_results(assigns) %>
        <p style="font-size:0.7rem;color:var(--text-muted);margin-bottom:0.6rem">
          {length(results)} match{if length(results) == 1, do: "", else: "es"} across all tabs
        </p>
        <div style="display:flex;flex-direction:column;gap:0.6rem">
          <%= for {q, status} <- results do %>
            <.question_card
              q={q}
              status={status}
              show_status_badge={true}
              is_admin={@is_admin}
              game={@game}
              favorited_ids={@favorited_ids}
              flagged_ids={@flagged_ids}
              vote_counts={@vote_counts}
              user_votes={@user_votes}
              asker_confirmed={@asker_confirmed}
              expanded={@expanded}
              current_user_id={@current_user.id}
            />
          <% end %>
          <p :if={results == []} style="font-size:0.75rem;color:var(--text-muted)">
            No questions match your search.
          </p>
        </div>
      <% else %>
        <%!-- Tab strip --%>
        <%!-- On phones (<=640px) the word labels hide via .hide-mobile, leaving
              emoji + count so all three tabs fit without sideways scroll.
              overflow-x:auto stays as a safety net for edge cases. --%>
        <div style="display:flex;gap:0.35rem;margin-bottom:1rem;border-bottom:1px solid var(--border);overflow-x:auto;scrollbar-width:none">
          <.tab_button
            tab="verified"
            active={@tab == "verified"}
            emoji="✅"
            word="Verified"
            count={length(@verified_questions)}
          />
          <.tab_button
            tab="community"
            active={@tab == "community"}
            emoji="🌐"
            word="Community"
            count={length(@community_questions)}
          />
          <.tab_button
            tab="unverified"
            active={@tab == "unverified"}
            emoji="🧪"
            word="Unverified"
            count={length(@unverified_questions)}
          />
        </div>

        <% questions = tab_questions(assigns) %>
        <% status = @tab %>

        <%!-- Intro banner — copy varies by tab; category pills + grouping below
             are shared across all three tabs so unverified questions are just as
             browsable-by-category as verified/community ones. --%>
        <%= if questions != [] do %>
          <%= if @tab == "unverified" do %>
            <div style="display:flex;align-items:center;gap:0.6rem;padding:0.6rem 0.75rem;margin-bottom:1.25rem;background:var(--bg-surface);border:1px solid var(--border);border-left:3px solid var(--orange,orange);border-radius:0.4rem">
              <span style="font-size:1.1rem;line-height:1">🧪</span>
              <p style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;margin:0">
                Questions other players asked, <strong>not yet reviewed</strong>
                by the community. Answers cite the rulebook but haven't been vetted — double-check before relying on one. Upvoting an answer counts toward community promotion and adds it to your own questions list.
              </p>
            </div>
          <% else %>
            <div style="display:flex;align-items:center;gap:0.6rem;padding:0.6rem 0.75rem;margin-bottom:1.25rem;background:var(--bg-surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:0.4rem">
              <span style="font-size:1.1rem;line-height:1">📖</span>
              <p style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;margin:0">
                These answers are <strong>drawn from the official rules</strong>
                and surfaced by {if @tab == "verified", do: "admins", else: "the community"} as the most helpful. Always double-check the rulebook for anything that matters.
              </p>
            </div>
          <% end %>
        <% end %>

        <%!-- Category filter pills — only categories that actually tag a question
             in this tab, so every pill yields results when clicked. --%>
        <% shown_cats = categories_with_questions(@categories, questions, @category_map) %>
        <%= if shown_cats != [] do %>
          <div style="display:flex;flex-wrap:wrap;gap:0.35rem;margin-bottom:1.25rem">
            <%= for cat <- shown_cats do %>
              <button
                type="button"
                phx-click="filter_category"
                phx-value-id={cat.id}
                style={"font-size:0.65rem;padding:0.2rem 0.55rem;border-radius:1rem;border:1px solid #{if @filter_category == cat.id, do: "var(--accent)", else: "var(--border)"};background:#{if @filter_category == cat.id, do: "var(--accent)", else: "var(--bg-subtle)"};color:#{if @filter_category == cat.id, do: "var(--accent-text,#fff)", else: "var(--text-secondary)"};cursor:pointer"}
              >
                {cat.name}
              </button>
            <% end %>
            <button
              :if={@filter_category != nil}
              type="button"
              phx-click="filter_category"
              phx-value-id={@filter_category}
              style="font-size:0.65rem;padding:0.2rem 0.55rem;border-radius:1rem;border:1px solid var(--border);background:var(--bg-subtle);color:var(--text-muted);cursor:pointer"
            >
              Clear ✕
            </button>
          </div>
        <% end %>

        <%= if questions == [] do %>
          <p style="font-size:0.8rem;color:var(--text-muted)">
            <%= case @tab do %>
              <% "verified" -> %>
                No admin-verified answers yet for this game.
              <% "unverified" -> %>
                Nothing waiting for review — every answered question has been promoted or verified.
              <% _ -> %>
                No community answers yet for this game.
            <% end %>
          </p>
        <% else %>
          <%= if @filter_category do %>
            <%!-- Filtered view: single category --%>
            <% filtered = questions_for_category(questions, @category_map, @filter_category) %>
            <% current_cat = Enum.find(@categories, &(&1.id == @filter_category)) %>
            <%= if current_cat do %>
              <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.6rem">
                {current_cat.name}
              </h2>
              <p
                :if={current_cat.description}
                style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;margin-bottom:0.9rem;padding:0.6rem 0.75rem;background:var(--bg-surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:0.4rem"
              >
                {current_cat.description}
              </p>
            <% end %>
            <div style="display:flex;flex-direction:column;gap:0.6rem">
              <%= for q <- filtered do %>
                <.question_card
                  q={q}
                  status={status}
                  show_status_badge={false}
                  is_admin={@is_admin}
                  game={@game}
                  favorited_ids={@favorited_ids}
                  flagged_ids={@flagged_ids}
                  vote_counts={@vote_counts}
                  user_votes={@user_votes}
                  asker_confirmed={@asker_confirmed}
                  expanded={@expanded}
                  current_user_id={@current_user.id}
                />
              <% end %>
              <p :if={filtered == []} style="font-size:0.75rem;color:var(--text-muted)">
                No questions in this category yet.
              </p>
            </div>
          <% else %>
            <%!-- All categories view --%>
            <%= for cat <- @categories do %>
              <% cat_qs = questions_for_category(questions, @category_map, cat.id) %>
              <%= if cat_qs != [] do %>
                <div id={"category-#{cat.id}"} style="margin-bottom:1.75rem">
                  <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.5rem;display:flex;align-items:center;gap:0.4rem">
                    {cat.name}
                    <span style="font-size:0.65rem;font-weight:400;color:var(--text-muted)">({length(
                      cat_qs
                    )})</span>
                  </h2>
                  <div style="display:flex;flex-direction:column;gap:0.6rem">
                    <%= for q <- cat_qs do %>
                      <.question_card
                        q={q}
                        status={status}
                        show_status_badge={false}
                        is_admin={@is_admin}
                        game={@game}
                        favorited_ids={@favorited_ids}
                        flagged_ids={@flagged_ids}
                        vote_counts={@vote_counts}
                        user_votes={@user_votes}
                        asker_confirmed={@asker_confirmed}
                        expanded={@expanded}
                        current_user_id={@current_user.id}
                      />
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
            <%!-- Untagged --%>
            <% untagged = untagged_questions(questions, @category_map) %>
            <%= if untagged != [] do %>
              <div id="category-general" style="margin-bottom:1.75rem">
                <h2 style="font-size:0.85rem;font-weight:700;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-secondary);margin-bottom:0.5rem">
                  General
                </h2>
                <div style="display:flex;flex-direction:column;gap:0.6rem">
                  <%= for q <- untagged do %>
                    <.question_card
                      q={q}
                      status={status}
                      show_status_badge={false}
                      is_admin={@is_admin}
                      game={@game}
                      favorited_ids={@favorited_ids}
                      flagged_ids={@flagged_ids}
                      vote_counts={@vote_counts}
                      user_votes={@user_votes}
                      asker_confirmed={@asker_confirmed}
                      expanded={@expanded}
                      current_user_id={@current_user.id}
                    />
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
    </div>

    <%!-- Floating tool windows + minimized dock, same machinery as the game
          page. This page has no fixed .chat-layout, so no stacking-context
          trap — but keep them at the root for symmetry. --%>
    <ToolPanel.tool_panel {assigns} />
    """
  end

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      aria-label={"#{@word} (#{@count})"}
      style={"font-size:0.72rem;font-weight:#{if @active, do: "700", else: "500"};padding:0.4rem 0.7rem;border:none;border-bottom:2px solid #{if @active, do: "var(--accent)", else: "transparent"};background:none;color:#{if @active, do: "var(--text)", else: "var(--text-secondary)"};cursor:pointer;white-space:nowrap;flex-shrink:0"}
    >
      {@emoji}<span class="hide-mobile">&nbsp;{@word}</span> ({@count})
    </button>
    """
  end

  # Flatten markdown to plain text for the card preview. The preview is a short
  # slice, so rendering real markdown (and slicing the HTML) would emit broken
  # tags — strip the syntax to readable text instead.
  defp strip_markdown(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/__(.+?)__/, "\\1")
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/_(.+?)_/, "\\1")
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/^>\s?/m, "")
    |> String.replace(~r/^[-*+]\s+/m, "")
    |> String.replace(~r/^\d+\.\s+/m, "")
    |> String.replace(~r/\s*\n\s*\n\s*/, " ")
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.trim()
  end

  defp render_markdown(text) do
    case MDEx.to_html(text) do
      {:ok, html} ->
        html
        |> then(&"<div class=\"md-answer\" style=\"line-height:1.4;margin:0\">#{&1}</div>")
        |> Phoenix.HTML.raw()

      {:error, _} ->
        text
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.raw()
    end
  end

  # A group row publishes only scrubbed text — never the asker's raw wording.
  # This is `display_question/1` minus its final `|| q.question` fallback:
  # `cleaned_question` is the normalize step's scrubbed output (and the exact
  # text PublishCheckWorker screened before flipping `browsable`), while
  # `question` is the asker's verbatim prose. A group row with neither cannot
  # be browsable, so the withheld fallback is unreachable in practice — it's
  # here so a future caller can't accidentally leak raw text.
  defp listed_question(q), do: QuestionLog.listed_question(q)

  defp question_card(assigns) do
    ~H"""
    <div style="padding:0.75rem;border:1px solid var(--border);border-radius:0.45rem;background:var(--bg-surface)">
      <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:0.75rem">
        <div style="flex:1;min-width:0">
          <%!-- The whole question row (full card width) toggles the inline
              expansion; opening the chat thread for promoted rows lives in
              the ⋯ menu instead. --%>
          <div
            role="button"
            tabindex="0"
            phx-click="toggle_expand"
            phx-value-id={@q.id}
            style="font-size:0.82rem;font-weight:600;color:var(--text);cursor:pointer;word-break:break-word;line-height:1.4;margin:-0.75rem 0 0.35rem -0.75rem;padding:0.75rem 0 0 0.75rem"
            title={
              if MapSet.member?(@expanded, @q.id),
                do: "Collapse the answer",
                else: "Show the full answer and rulebook citations"
            }
          >
            {listed_question(@q)}
            <span style="color:var(--text-muted);font-weight:400">
              {if MapSet.member?(@expanded, @q.id), do: "▴", else: "▾"}
            </span>
          </div>
          <%= if MapSet.member?(@expanded, @q.id) do %>
            <div style="font-size:0.75rem;color:var(--text);word-break:break-word">
              {render_markdown(@q.canonical_answer || @q.answer || "")}
            </div>
            <.citation_cards q={@q} />
            <%!-- Plain-styled toggle: the generic `button` reset (nowrap,
                inline-flex, hover lift) fights text-like buttons, so use a
                clickable span with a button role instead. --%>
            <span
              role="button"
              tabindex="0"
              phx-click="toggle_expand"
              phx-value-id={@q.id}
              title="Collapse the answer"
              style="display:inline-block;font-size:0.68rem;color:var(--text-muted);margin-top:0.3rem;cursor:pointer"
            >
              Show less ▴
            </span>
          <% else %>
            <% preview = strip_markdown(@q.canonical_answer || @q.answer || "") %>
            <div
              role="button"
              tabindex="0"
              phx-click="toggle_expand"
              phx-value-id={@q.id}
              title="Show the full answer and rulebook citations"
              style="font-size:0.72rem;color:var(--text-secondary);line-height:1.45;word-break:break-word;cursor:pointer"
            >
              {String.slice(preview, 0, 220)}
              <%= if String.length(preview) > 220 do %>
                <span style="color:var(--text-muted)">…</span>
              <% end %>
            </div>
          <% end %>
          <div style="display:flex;flex-wrap:wrap;gap:0.3rem;margin-top:0.4rem;align-items:center">
            <%!-- Vote controls: same store and semantics as the Q&A interface.
                For another player's unverified answer, an upvote also adds the
                question to the voter's own list. --%>
            <% cv = Map.get(@user_votes, @q.id) %>
            <% counts = Map.get(@vote_counts, @q.id, %{up: 0, down: 0}) %>
            <span style="display:inline-flex;align-items:center;gap:0.15rem;margin-right:0.2rem">
              <.vote_thumb
                event="vote"
                id={@q.id}
                voted={cv == "up"}
                count={Map.get(counts, :up, 0)}
                title={
                  cond do
                    cv == "up" -> "Remove vote"
                    @q.user_id == @current_user_id -> "Confirm this answered your question"
                    @status == "unverified" -> "Helpful — also adds it to your questions list"
                    true -> "Helpful"
                  end
                }
              />
              <span
                :if={MapSet.member?(@asker_confirmed, @q.id)}
                style="font-size:0.6rem;color:var(--accent-ink, var(--accent));border:1px solid currentColor;border-radius:0.5rem;padding:0 0.35rem;line-height:1.4;white-space:nowrap"
                title="Count includes the asker, who confirmed this answered their question"
              >✓ asker</span>
            </span>
            <span
              :if={@show_status_badge && @status == "unverified"}
              style="font-size:0.6rem;font-weight:600;color:var(--orange,orange);background:color-mix(in srgb, orange 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              🧪 Unverified
            </span>
            <span
              :if={@show_status_badge && @status == "community"}
              style="font-size:0.6rem;font-weight:600;color:var(--accent-ink, var(--accent));background:color-mix(in srgb, var(--accent) 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              🌐 Community
            </span>
            <span
              :if={@q.verified}
              style="font-size:0.6rem;font-weight:600;color:var(--green);background:color-mix(in srgb, var(--green) 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              ✅ Admin-verified
            </span>
            <span
              :if={@q.canonical_question}
              style="font-size:0.6rem;font-weight:600;color:var(--accent-ink, var(--accent));background:color-mix(in srgb, var(--accent) 14%, var(--bg-surface));padding:0.1rem 0.4rem;border-radius:1rem"
            >
              ★ Curated
            </span>
            <span
              :if={citation_pages(@q) != []}
              style="font-size:0.6rem;font-weight:600;color:var(--text-secondary);background:var(--bg-subtle);padding:0.1rem 0.4rem;border-radius:1rem"
            >
              📖 Rulebook p.{Enum.join(citation_pages(@q), ", ")}
            </span>
            <span
              :if={citation_pages(@q) == [] && @q.citation_valid}
              style="font-size:0.6rem;font-weight:600;color:var(--text-secondary);background:var(--bg-subtle);padding:0.1rem 0.4rem;border-radius:1rem"
            >
              📖 Cited from rulebook
            </span>
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:0.35rem;flex-shrink:0">
          <!-- Overflow: secondary actions (favorite, copy, open, regenerate, report) -->
          <details class="card-menu">
            <summary class="card-menu__trigger" title="More actions">⋯</summary>
            <div class="card-menu__pop card-menu__pop--right">
              <button
                type="button"
                phx-click="favorite_community_answer"
                phx-value-id={@q.id}
                class="card-menu__item"
                title={
                  if MapSet.member?(@favorited_ids, @q.id),
                    do: "Remove from your favorites",
                    else: "Favorite — moves to top of this list"
                }
              >
                {if MapSet.member?(@favorited_ids, @q.id), do: "♥ Unfavorite", else: "♡ Favorite"}
              </button>
              <button
                type="button"
                id={"community-copy-#{@q.id}"}
                phx-hook="ClipboardCopy"
                data-clipboard-text={"Q: #{listed_question(@q)}\n\nA: #{strip_markdown(@q.canonical_answer || @q.answer || "")}"}
                class="card-menu__item"
                title="Copy question and answer"
              >📋 Copy Q&amp;A</button>
              <button
                type="button"
                id={"community-share-#{@q.id}"}
                phx-hook="ShareCard"
                data-share-game={@game.name}
                data-share-question={listed_question(@q)}
                data-share-answer={strip_markdown(@q.canonical_answer || @q.answer || "")}
                data-share-page={@q.cited_page}
                class="card-menu__item"
                title="Download this Q&A as an image for the group chat"
              >🖼 Share as image</button>
              <.link
                :if={@status != "unverified"}
                navigate={~p"/games/#{@game}?t=#{RuleMaven.Hashid.encode(@q.id)}"}
                class="card-menu__item"
                title="Open this answer as a chat thread"
              >💬 Open in chat</.link>
              <.link
                :if={@status != "unverified"}
                navigate={~p"/games/#{@game}?t=#{RuleMaven.Hashid.encode(@q.id)}"}
                class="card-menu__item"
                title="Open this answer in the chat to generate a fresh version"
              >↻ Regenerate</.link>
              <%= if @is_admin do %>
                <!-- Admins don't report (they ARE the moderators) — direct
                     pull into the moderation queue instead. Softer than the
                     ✕ reject next door: pull keeps it recoverable via review. -->
                <button
                  type="button"
                  phx-click="pull_for_review"
                  phx-value-id={@q.id}
                  data-confirm="Pull this answer from the Community Q&A for review? It stays out until re-approved."
                  class="card-menu__item"
                  title="Pull into the moderation queue"
                >⏸ Pull for review</button>
              <% else %>
                <%= if MapSet.member?(@flagged_ids, @q.id) do %>
                  <button
                    type="button"
                    disabled
                    class="card-menu__item"
                    style="opacity:0.6;cursor:default"
                    title="You reported this answer"
                  >✓ Reported</button>
                <% else %>
                  <button
                    type="button"
                    phx-click="report_answer"
                    phx-value-id={@q.id}
                    class="card-menu__item"
                    title="Report a wrong or unhelpful answer"
                  >🚩 Report</button>
                <% end %>
              <% end %>
            </div>
          </details>

          <%= if @is_admin && @status != "unverified" do %>
            <button
              phx-click="reject"
              phx-value-id={@q.id}
              class="btn-icon btn-xs"
              title="Remove from community"
            >✕</button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
