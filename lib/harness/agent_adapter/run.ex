defmodule Harness.AgentAdapter.Run do
  @moduledoc """
  Handle to a spawned agent run.

  Returned by `Harness.AgentAdapter.invoke/2` and threaded through every
  `c:Harness.AgentAdapter.classify_message/2` call for that run. Every field
  except `adapter_state` is harness-owned and read-only to adapters;
  `adapter_state` is the adapter's private scratchpad.
  """

  @typedoc """
  Run handle.

    * `ref` — a stable, unique run id. Survives the `port` being replaced if a
      run is resumed.
    * `adapter` — the `Harness.AgentAdapter` module driving the run.
    * `port` — the OTP port the agent's OS process is connected to.
    * `os_pid` — the agent's OS process id, captured once at spawn. `nil` only
      when the port had already closed before the pid could be read; otherwise
      it is the spawn-time pid and is not cleared when the agent later exits.
    * `started_at` — `System.monotonic_time/0` captured at spawn. Wall-clock
      duration is derived by the run-lifecycle layer, not the adapter.
    * `adapter_state` — adapter-private term (e.g. a line-buffer remainder).
      Harness treats it as opaque.
  """
  @type t :: %__MODULE__{
          ref: reference(),
          adapter: module(),
          port: port(),
          os_pid: non_neg_integer() | nil,
          started_at: integer(),
          adapter_state: term()
        }

  @enforce_keys [:ref, :adapter, :port, :os_pid, :started_at]
  defstruct [:ref, :adapter, :port, :os_pid, :started_at, adapter_state: nil]
end
