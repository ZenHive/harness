defmodule Harness.Store.EtsHeir do
  @moduledoc false
  # Quiet keeper process so a named ETS table outlives the process that created
  # it without dumping `{:ETS-TRANSFER, ...}` on a supervisor mailbox.

  @doc "Returns the registered heir pid, spawning one if needed."
  @spec pid(atom()) :: pid()
  def pid(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> pid
      nil -> spawn_heir(name)
    end
  end

  @spec spawn_heir(atom()) :: pid()
  defp spawn_heir(name) do
    pid = spawn(&loop/0)

    try do
      Process.register(pid, name)
      pid
    rescue
      ArgumentError ->
        Process.exit(pid, :kill)

        case Process.whereis(name) do
          existing when is_pid(existing) -> existing
          nil -> spawn_heir(name)
        end
    end
  end

  @spec loop() :: no_return()
  defp loop do
    receive do
      _ -> loop()
    end
  end
end
