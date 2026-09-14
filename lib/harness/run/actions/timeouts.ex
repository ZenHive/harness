defmodule Harness.Run.Actions.Timeouts do
  @moduledoc false

  alias Harness.AgentAdapter.Run, as: AgentRun

  @reviewer_idle_floor 600_000
  @implementer_idle_floor 600_000

  # Tool-output heartbeats reset byte-idle but do not reset the progress
  # watchdog. Long checks can therefore exhaust the adapter's five-minute
  # default without being stalled. Give default progress windows fifteen
  # minutes; explicit run budgets still take precedence.
  @reviewer_progress_floor 900_000
  @implementer_progress_floor 900_000

  @type state :: Harness.Run.state()
  @type data :: map()
  @type handler_result :: term()
  # Re-arm the idle watchdog on implementer progress — but ONLY once the
  # implementer handle is captured. Before the handle arrives there is no OS pid
  # to reap directly, so the lifetime timeout remains the backstop.
  @doc false
  @spec rearm_running_idle(state(), data(), handler_result()) :: handler_result()
  def rearm_running_idle(:running, %{agent_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, running_idle_timeout(data), :implementer_idle_timeout}]}
  end

  def rearm_running_idle(_state, _data, result), do: result

  # Re-arm the idle watchdog on reviewer progress — but ONLY once the reviewer
  # handle is captured (reviewer_run set). Before the handle arrives the spawn
  # watchdog owns the single state_timeout; a stray/early transcript chunk must
  # not replace it with the longer idle window (Task 199 audit).
  @doc false
  @spec rearm_reviewing_idle(state(), data(), handler_result()) :: handler_result()
  def rearm_reviewing_idle(:reviewing, %{reviewer_run: %AgentRun{}} = data, {:keep_state, next_data}) do
    {:keep_state, next_data, [{:state_timeout, reviewing_idle_timeout(data), :reviewer_idle_timeout}]}
  end

  def rearm_reviewing_idle(_state, _data, result), do: result

  @doc false
  @spec reviewer_spawn_timeout_report(data()) :: String.t()
  def reviewer_spawn_timeout_report(data) do
    "Reviewer agent never spawned within #{data.reviewer_spawn_timeout}ms."
  end

  @doc false
  @spec reviewer_idle_timeout_report(data()) :: String.t()
  def reviewer_idle_timeout_report(data) do
    "Reviewer made no progress within #{reviewing_idle_timeout(data)}ms."
  end

  # Idle window for the gen_statem-level :running watchdog. The explicit
  # :implementer_idle_timeout run opt exists so tests can prove the mechanics
  # without waiting for the production floor; normal dispatches use idle_timeout
  # with the implementer floor below.
  @doc false
  @spec running_idle_timeout(data()) :: timeout()
  def running_idle_timeout(%{implementer_idle_timeout: idle}) when not is_nil(idle), do: idle

  def running_idle_timeout(data), do: implementer_idle_timeout(data.idle_timeout)

  # Floors the implementer-phase idle window at @implementer_idle_floor so a
  # silent compile/test/dialyzer command cannot trip the watchdog. `nil` becomes
  # the floor; explicit lower values are raised to it; explicit higher values
  # win. `@doc false` public so the floor is unit-testable without a live run.
  @doc false
  @spec implementer_idle_timeout(timeout() | nil) :: timeout()
  def implementer_idle_timeout(nil), do: @implementer_idle_floor
  def implementer_idle_timeout(:infinity), do: :infinity
  def implementer_idle_timeout(idle) when is_integer(idle), do: max(idle, @implementer_idle_floor)

  # Idle window for the gen_statem-level :reviewing watchdog. An explicit
  # `:reviewing_idle_timeout` run opt wins (tests); otherwise the same floor as
  # the Driver's reviewing idle window.
  @doc false
  @spec reviewing_idle_timeout(data()) :: pos_integer()
  def reviewing_idle_timeout(%{reviewing_idle_timeout: idle}) when is_integer(idle), do: idle

  def reviewing_idle_timeout(data), do: reviewer_idle_timeout(data.idle_timeout)

  # Floors the reviewing-phase idle window at @reviewer_idle_floor so a silent
  # check run can't idle-kill the reviewer before it writes the verdict (Task
  # 181). `nil` (no caller override → Driver applies its 5-min default) becomes
  # the floor; an explicit idle_timeout below the floor is raised to it; an
  # explicit higher value wins. `@doc false` public so the floor is unit-testable
  # without a live reviewer run.
  @doc false
  @spec reviewer_idle_timeout(timeout() | nil) :: timeout()
  def reviewer_idle_timeout(nil), do: @reviewer_idle_floor
  def reviewer_idle_timeout(:infinity), do: :infinity
  def reviewer_idle_timeout(idle) when is_integer(idle), do: max(idle, @reviewer_idle_floor)

  @doc false
  @spec reviewer_progress_timeout(timeout() | nil) :: timeout()
  def reviewer_progress_timeout(nil), do: configured_progress_timeout(@reviewer_progress_floor)
  def reviewer_progress_timeout(progress), do: progress

  @doc false
  @spec implementer_progress_timeout(timeout() | nil) :: timeout()
  def implementer_progress_timeout(nil), do: configured_progress_timeout(@implementer_progress_floor)
  def implementer_progress_timeout(progress), do: progress

  @spec configured_progress_timeout(pos_integer()) :: timeout()
  defp configured_progress_timeout(floor) do
    :harness_agent_adapter
    |> Application.get_env(:run, [])
    |> Keyword.get(:progress_timeout, floor)
    |> max(floor)
  end
end
