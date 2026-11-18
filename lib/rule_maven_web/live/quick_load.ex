defmodule RuleMavenWeb.QuickLoad do
  @moduledoc """
  Off-the-join loading that still renders in one go when it can.

  A connected mount runs in the LiveView socket process, so slow work there
  holds the join (PLATFORM.md §6). `start_async/3` moves it off, but then the
  page always paints a loading state first and swaps the data in a moment
  later — a flicker on every live navigation, even when the work takes 20ms.

  `start/2` runs the work in its own process and waits up to `budget_ms` for
  it: done in time → `{:done, result}` and the page renders complete in its
  first paint; slower → `{:pending, ref}`, the page shows its loading state,
  and the result arrives as `{:DOWN, ref, :process, _, reason}` — pass the
  reason to `result/1`. Either way the result is `{:ok, value}` or
  `{:error, reason}` (the work raised or exited).

      case QuickLoad.start(fn -> compute() end) do
        {:done, result} -> apply_load(socket, result)
        {:pending, ref} -> assign(socket, load_ref: ref)
      end

      def handle_info({:DOWN, ref, :process, _, reason}, %{assigns: %{load_ref: ref}} = socket),
        do: {:noreply, socket |> assign(load_ref: nil) |> apply_load(QuickLoad.result(reason))}

  The work process inherits `$callers` (Ecto sandbox allowances in tests,
  like `start_async`) and is monitored, not linked: a crash in it is a result,
  never a crash of the page.
  """

  @budget_ms 150

  @spec start((-> term()), non_neg_integer()) ::
          {:done, {:ok, term()} | {:error, term()}} | {:pending, reference()}
  def start(fun, budget_ms \\ @budget_ms) when is_function(fun, 0) do
    callers = [self() | Process.get(:"$callers", [])]

    {_pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        exit(
          try do
            {__MODULE__, :ok, fun.()}
          rescue
            e -> {__MODULE__, :error, e}
          catch
            kind, reason -> {__MODULE__, :error, {kind, reason}}
          end
        )
      end)

    receive do
      {:DOWN, ^ref, :process, _, reason} -> {:done, result(reason)}
    after
      budget_ms -> {:pending, ref}
    end
  end

  @doc "The `{:ok, value} | {:error, reason}` carried by the work process's exit reason."
  def result({__MODULE__, :ok, value}), do: {:ok, value}
  def result({__MODULE__, :error, reason}), do: {:error, reason}
  def result(reason), do: {:error, reason}
end
