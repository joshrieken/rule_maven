defmodule RuleMavenWeb.AdminLive.Threads do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Games, Users}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if Users.game_master?(socket.assigns.current_user) do
      threads = Games.all_question_threads()

      {:ok,
       assign(socket,
         page_title: "Review Threads",
         threads: threads,
         merge_thread_root: nil,
         merge_question: "",
         merge_answer: ""
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("prepare_merge", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    thread = Enum.find(socket.assigns.threads, &(&1.root.id == id))

    if thread do
      followups = thread.followups
      answer = build_consolidated_answer(thread.root, followups)

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

    if is_nil(thread) do
      {:noreply, put_flash(socket, :error, "No thread selected.")}
    else
      root = thread.root

      Repo.update_all(
        from(q in QuestionLog, where: q.id == ^root.id),
        set: [
          visibility: "community",
          canonical_question: socket.assigns.merge_question,
          canonical_answer: socket.assigns.merge_answer
        ]
      )

      RuleMaven.Workers.EmbedQuestionWorker.enqueue(root.id)

      threads = Games.all_question_threads()

      {:noreply,
       assign(socket,
         threads: threads,
         merge_thread_root: nil,
         merge_question: "",
         merge_answer: ""
       )
       |> put_flash(:info, "Thread promoted to community!")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:52rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Review Threads</h1>

      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        Review root questions with their followups. Merge into FAQ entries. ({length(@threads)} threads)
      </p>

      <!-- Merge form -->
      <%= if @merge_thread_root do %>
        <div style="background:var(--bg-surface);border:2px solid var(--accent);border-radius:0.5rem;padding:1rem;margin-bottom:1rem">
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
                style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg-surface);color:var(--text);resize:vertical"
              ><%= @merge_question %></textarea>
            </div>
            <div>
              <label style="display:block;font-size:0.75rem;font-weight:600;color:var(--text-muted);margin-bottom:0.15rem">Answer (markdown)</label>
              <textarea
                name="merge_answer"
                phx-change="merge_form_change"
                rows="6"
                style="width:100%;border:1px solid var(--border);border-radius:0.25rem;padding:0.25rem 0.5rem;font-size:0.75rem;background:var(--bg-surface);color:var(--text);resize:vertical"
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
          <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:0.375rem;padding:0.6rem 0.75rem">
            <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:0.5rem">
              <div style="flex:1;min-width:0">
                <div style="font-weight:600;font-size:0.8rem;color:var(--text);margin-bottom:0.25rem">
                  <span style="color:var(--text-muted);font-weight:400">[{root.game &&
                    root.game.name}]</span> {String.slice(root.question, 0, 100)}
                </div>
                <div style="font-size:0.8rem;color:var(--text-muted);line-height:1.4">
                  {String.slice(root.answer || "", 0, 150)}{if String.length(root.answer || "") >
                                                                 150,
                                                               do: "…"}
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
              >Promote to Community<br/>(Merge thread)</button>
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
    """
  end

  defp build_consolidated_answer(root, followups) do
    parts = ["**Original:** #{root.answer}"]

    parts =
      if followups != [] do
        fu = Enum.map_join(followups, "\n\n", fn f -> "**Q: #{f.question}**\nA: #{f.answer}" end)
        parts ++ ["**Follow-ups:**\n#{fu}"]
      else
        parts
      end

    Enum.join(parts, "\n\n---\n\n")
  end
end
