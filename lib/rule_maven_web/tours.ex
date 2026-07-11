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
        body:
          "This menu holds ready-made questions players commonly ask about this game, plus a Settle-an-argument helper for when the table disagrees."
      },
      %{
        sel: "[data-tour='voices']",
        title: "Answer personas",
        body:
          "Have answers delivered in a themed character voice. Pure fun — the rules content stays exactly as accurate."
      },
      %{
        # Targets the empty-state opt-in button (present on both mobile and
        # desktop, and only when the game has a palette). The button self-hides
        # once a game variant is already active, so on replay this step just
        # skips via present()'s rendered-box check — same graceful degrade as a
        # palette-less game.
        sel: "#game-theme-hint",
        title: "Dress for the game",
        body:
          "One tap paints the whole page in this game's own colors, drawn from its cover art. It sticks with this game — your everyday theme won't override it, and the game look is waiting when you come back. Turn it off anytime from the 🖌️ theme menu."
      },
      %{
        sel: "[data-tour='expansions']",
        title: "Playing with expansions?",
        body:
          "This shows what you're playing with. Tap it to add or remove expansions — answers adjust to match."
      },
      %{
        sel: "[data-tour='tools-subbar']",
        title: "Every table tool lives here",
        body:
          "Tap 🎲 Play or 📚 Learn to open Turn Wizard, Quiz, Setup checklist, Score pad, and more — they open as movable panels you can minimize to the dock, and they remember where you left off."
      },
      # Deliberately un-anchored (`sel: nil`, a centered step). The obvious
      # anchor — [data-tour='group-selector'] — only renders for a user who
      # already belongs to a crew, i.e. never for the new user this tour is
      # written for, and a data-tour on an absent element is silently skipped.
      %{
        sel: nil,
        title: "Asking for your group",
        body:
          "Join a crew and everyone in it sees your questions and answers live — and if someone already asked, the rest of the crew gets the instant cached answer. Create or join one from My Groups in your user menu; once you're in, a picker appears up here to choose who you're asking for."
      },
      %{
        sel: nil,
        title: "Good to go! 🎲",
        body:
          "When your first answer arrives, a short walkthrough will show you around it — verdict, confidence, citations, and how voting earns you curator points. Full guide + FAQ on the Help page."
      }
    ],
    # Auto-starts when the user's first real answer lands (pushed from
    # :ask_complete in GameLive.Show) — a live answer beats a faked screenshot,
    # and every selector below is guaranteed to exist at that moment.
    "answer" => [
      %{
        sel: ".chat-msg .verdict-stamp",
        title: "The verdict",
        body:
          "Your ruling at a glance: legal move, not allowed, in the rules, or rules silent — before you read a word."
      },
      %{
        sel: ".chat-msg .conf-pill",
        title: "Confidence meter",
        body:
          "How solid this answer is. Full marks means strong rulebook backing; lower means double-check the cited passage at the table."
      },
      %{
        sel: "[data-tour='citation']",
        title: "Straight from the rulebook",
        body:
          "Every answer quotes the exact passage it's based on, with source and page — so you can verify it in your own copy in seconds."
      },
      %{
        sel: "[data-tour='answer-vote']",
        title: "Vote on answers",
        body:
          "A 👍 confirms the answer helped. Votes decide which answers the whole community sees first — and they're how you earn curator points."
      },
      %{
        sel: "[data-tour='related']",
        title: "Keep digging",
        body: "Related and follow-up questions are one tap away — no retyping."
      },
      %{
        sel: nil,
        title: "Become a curator 🏆",
        body:
          "When the community settles on an answer you voted for, you earn curator points — they unlock badges and bonus question quota. Track it all on your Standing page (user menu)."
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
  Whether a tour should auto-start for the current user (connected socket,
  logged in, not seen yet). Rendered into the hook element's
  `data-tour-autostart` attribute — the Tour hook reads it on mount and asks
  for the tour over a normal event round-trip. A `push_event` at mount time is
  NOT reliable here: events riding the join reply are dropped if the client
  retries the join, which intermittently ate the auto-start.
  """
  def autostart?(socket, tour_id) do
    user = socket.assigns[:current_user]
    connected?(socket) and user != nil and not Users.tour_seen?(user, tour_id)
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
