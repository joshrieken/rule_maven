defmodule RuleMaven.Auth.LoginThrottle do
  @moduledoc """
  In-memory, fixed-window throttle for credential endpoints (login, password
  reset) to blunt brute-force and email-bombing. Keyed per {ip, identifier}, so
  a single attacker IP guessing one username is limited without locking out
  everyone behind a shared NAT for a different username.

  Backed by a public ETS table owned by this GenServer. `check/1` and
  `record_failure/1` read/write ETS directly (no GenServer round-trip). A
  periodic sweep drops expired windows so the table doesn't grow unbounded.
  """
  use GenServer

  @table :login_throttle
  @max_attempts 5
  @window_seconds 900
  @sweep_interval_ms 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `:ok` if the key may attempt, `{:error, seconds_remaining}` if locked out.
  """
  def check(key) do
    case lookup(key) do
      {count, window_start} ->
        if count >= @max_attempts and within_window?(window_start) do
          {:error, @window_seconds - (now() - window_start)}
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  @doc "Records a failed attempt, opening or extending the current window."
  def record_failure(key) do
    if table_ready?() do
      case lookup(key) do
        {count, window_start} ->
          if within_window?(window_start) do
            :ets.insert(@table, {key, count + 1, window_start})
          else
            :ets.insert(@table, {key, 1, now()})
          end

        nil ->
          :ets.insert(@table, {key, 1, now()})
      end
    end

    :ok
  end

  @doc "Clears a key's counter (call on a successful auth)."
  def clear(key) do
    if table_ready?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Builds a throttle key from a connection's IP and an identifier string."
  def key(remote_ip, identifier) do
    {format_ip(remote_ip), String.downcase(to_string(identifier))}
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @window_seconds
    # match_delete rows whose window_start is older than the cutoff.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # --- helpers ---

  # Fail open: if the table isn't up (process not started yet, or this is an
  # already-running node that hasn't restarted after the child was added), never
  # block auth — a throttle outage must not become a login outage.
  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp lookup(key) do
    if table_ready?() do
      case :ets.lookup(@table, key) do
        [{^key, count, window_start}] -> {count, window_start}
        [] -> nil
      end
    else
      nil
    end
  end

  defp within_window?(window_start), do: now() - window_start < @window_seconds

  defp now, do: System.system_time(:second)

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)
end
