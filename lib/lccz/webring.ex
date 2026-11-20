defmodule Lccz.Webring do
  @moduledoc """
  The way into the Calzone Zone Ring: a secret old-web webring of made-up 1990s homepages that the
  hub keeps under `/ring` (`Hub.Ring`). Every app hides one faint grey 🥟 at the very foot of its
  pages, no label and nothing on hover, linking to `url/0`: it lands on a random member site
  (PLATFORM.md §3). The real apps aren't in the ring; they're only the way in.
  """

  @hub "https://lowcalcalzonezone.com"

  @doc "Where the 🥟 goes: a random site in the ring. `hub` is the hub's address (production's by default)."
  @spec url(String.t()) :: String.t()
  def url(hub \\ @hub), do: String.trim_trailing(hub, "/") <> "/ring/random"
end
