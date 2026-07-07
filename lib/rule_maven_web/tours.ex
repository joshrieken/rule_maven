defmodule RuleMavenWeb.Tours do
  @moduledoc """
  Spotlight onboarding tours: step definitions plus the LiveView plumbing that
  starts them.

  Each tour is a list of steps consumed by the `Tour` JS hook (a page places
  one `data-tour-page` element per tour, see `app.js`). A step highlights the
  element matching `sel`; a step with `sel: nil` renders as a centered card.
  Steps whose element isn't on the page are skipped client-side, so tours
  degrade gracefully (e.g. no expansions, empty game list).

  A tour auto-starts once per user (tracked in `users.tours_seen`) and can be
  replayed anytime from the user dropdown.
  """

  import Phoenix.LiveView, only: [push_event: 3, connected?: 1]
  import Phoenix.Component, only: [assign: 3]

  alias RuleMaven.Users

  @tours %{
    "games" => [
      %{
        sel: "#game-search",
        title: "Find your game",
        body:
          "Type here to filter the catalog. Any game with a ✓ Ready badge has its rulebook loaded and is ready for questions."
      },
      %{
        sel: "#view-tabs",
        title: "Your shelves",
        body:
          "Ready lists every game you can ask about. My Collection and Favorites keep your own games close at hand."
      },
      %{
        sel: "[data-tour='bgg-sync']",
        title: "Bring your collection",
        body:
          "Have a BoardGameGeek account? Sync it once and your whole collection appears here automatically."
      },
      %{
        sel: "#game-card-0",
        title: "Open a game",
        body: "Click any game to open its Q&A page — that's where the magic happens."
      },
      %{
        sel: nil,
        title: "That's it! 🎲",
        body:
          "Replay this tour anytime from your user menu (top right). The Help page there has a full guide and FAQ too."
      }
    ],
    "game" => [
      %{
        sel: "#ask-input",
        title: "Ask anything",
        body:
          "Plain English works: “Can I trade on my first turn?” Every answer is grounded in the rulebook and cites the passage it came from."
      },
      %{
        sel: "[data-tour='suggestions']",
        title: "Need inspiration?",
        body: "Browse ready-made questions players commonly ask about this game."
      },
      %{
        sel: "[data-tour='voices']",
        title: "Answer personas",
        body:
          "Have answers delivered in a themed character voice. Pure fun — the rules content stays exactly as accurate."
      },
      %{
        sel: "[data-tour='expansions']",
        title: "Playing with expansions?",
        body:
          "Toggle the ones on your table. Answers automatically account for their rule changes."
      },
      %{
        sel: "#setup-checklist",
        title: "Setup checklist",
        body:
          "Tick off components and setup steps as you lay out the game — expansion extras included."
      },
      %{
        sel: "[data-tour='dyk']",
        title: "Did you know?",
        body:
          "A random rule straight from the rulebook. Shuffle for another — great for the rules everyone forgets."
      },
      %{
        sel: "[data-tour='house-rules']",
        title: "House rules",
        body:
          "Save how your table actually plays. When an answer touches one of your house rules, you'll see a callout under it."
      },
      %{
        sel: nil,
        title: "Good to go! 🎲",
        body:
          "Once an answer arrives you can upvote it and check its confidence meter. Full guide + FAQ on the Help page — and you can replay this tour from your user menu."
      }
    ]
  }

  @doc "Known tour ids."
  def ids, do: Map.keys(@tours)

  @doc "Steps for a tour id, or nil."
  def steps(tour_id), do: Map.get(@tours, tour_id)

  @doc "Pushes a tour to the page's Tour hook, which runs it."
  def push_tour(socket, tour_id) do
    case steps(tour_id) do
      nil -> socket
      steps -> push_event(socket, "tour:start", %{id: tour_id, steps: steps})
    end
  end

  @doc """
  Starts a tour on first visit: pushes it when the socket is connected and the
  current user hasn't seen it yet. Call once per mount (or first
  handle_params); replays go through the "tour_replay" event instead.
  """
  def maybe_autostart(socket, tour_id) do
    user = socket.assigns[:current_user]

    if connected?(socket) and user && not Users.tour_seen?(user, tour_id) do
      push_tour(socket, tour_id)
    else
      socket
    end
  end

  @doc """
  Shared handlers for the Tour hook's events. Call from the LiveView:

      def handle_event("tour_" <> _ = event, params, socket),
        do: RuleMavenWeb.Tours.handle_event(event, params, socket)

  "tour_replay" re-pushes the requested tour; "tour_done" (complete or skip)
  stamps it seen so it stops auto-starting.
  """
  def handle_event("tour_replay", %{"id" => tour_id}, socket) do
    {:noreply, push_tour(socket, tour_id)}
  end

  def handle_event("tour_done", %{"id" => tour_id}, socket) do
    user = socket.assigns[:current_user]

    if user && tour_id in ids() && not Users.tour_seen?(user, tour_id) do
      case Users.mark_tour_seen(user, tour_id) do
        {:ok, updated} -> {:noreply, assign(socket, :current_user, updated)}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("tour_" <> _, _params, socket), do: {:noreply, socket}
end
