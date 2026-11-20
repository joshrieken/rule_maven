defmodule Lccz.Webring do
  @moduledoc """
  The Calzone Zone Ring, the old-web kind: every app links to the previous and next site in the
  ring, a random one, and the hub. Each app shows it in its footer with its own markup and styles
  (the hub's: `HubWeb.Components.webring/1`); this module only says where the links go.

  The ring's order and production addresses are fixed here; an app can pass its own addresses
  (e.g. the dev zone's *.lccz.localhost) by slug.
  """

  @ring [
    %{slug: "hub", name: "Low-Cal Calzone Zone", url: "https://lowcalcalzonezone.com"},
    %{slug: "rulemaven", name: "Rule Maven", url: "https://rulemaven.com"},
    %{slug: "stirandfold", name: "Stir & Fold", url: "https://stirandfold.com"},
    %{slug: "drawburn", name: "Drawburn", url: "https://drawburn.lowcalcalzonezone.com"}
  ]

  @type site :: %{slug: String.t(), name: String.t(), url: String.t()}

  @doc "Every site in the ring, in order, with `urls` (slug → address) overriding production's."
  @spec sites(map()) :: [site()]
  def sites(urls \\ %{}), do: Enum.map(@ring, &%{&1 | url: Map.get(urls, &1.slug, &1.url)})

  @doc """
  The links for the site `here` (a slug in the ring): `prev`, `next`, `random` (any other site) and
  `hub`. `pick` chooses the random one from a list (tests pass a fixed one).
  """
  @spec links(String.t(), map(), ([site()] -> site())) :: %{
          prev: site(),
          next: site(),
          random: site(),
          hub: site()
        }
  def links(here, urls \\ %{}, pick \\ &Enum.random/1) do
    sites = sites(urls)
    n = length(sites)
    i = Enum.find_index(sites, &(&1.slug == here)) || raise ArgumentError, "#{here} isn't in the ring"

    %{
      prev: Enum.at(sites, rem(i - 1 + n, n)),
      next: Enum.at(sites, rem(i + 1, n)),
      random: pick.(Enum.reject(sites, &(&1.slug == here))),
      hub: hd(sites)
    }
  end
end
