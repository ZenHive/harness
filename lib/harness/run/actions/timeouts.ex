defmodule Harness.Run.Actions.Timeouts do
  @moduledoc false

  alias Harness.AgentAdapter.Run, as: AgentRun

  @reviewer_idle_floor 600_000
  @implementer_idle_floor 600_000

  # The progress watchdog is the idle watchdog's stricter sibling: it reaps an
  # agent whose transcript shows no NEW tool call and whose worktree edit
  # fingerprint is unchanged (harness_agent_adapter Watchdog.expire_progress/1).
  # A single long check command — `mix ci`, `mix precommit`, `mix dialyzer` —
  # streams progress heartbeats but issues no new tool call and edits no source
  # file, so it looks exactly like a stalled agent. That is the same failure
  # Task 181 floored the idle window against, and it was reachable again here
  # because the driver's unfloored 300_000 default came through untouched:
  # observed 2026-09-14 on aave_sim run-1789369684790-eb07f7ac, where the
  # reviewer had already recorded precommit and dialyzer green in both MIX_ENVs,
  # started `mix ci` under its own 900_000 budget, and was reflex-halted with
  # {:reflex_halted, :progress_stalled} before it could write the verdict — the
  # run settled :review_stuck and a full green review was thrown away.
  #
  # The floor must therefore exceed the longest single silent check a project
  # runs, not the time an agent is allowed to think. Widen it on evidence of a
  # legitimate command outliving it, never to paper over a genuinely hung agent
  # — :total_timeout (30 min) and the run's lifetime budget remain the backstops.
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

  # Floors the reviewing-phase progress window at @reviewer_progress_floor, for
  # the reason given at the attribute. Same contract as the idle floors: `nil`
  # (no caller override, so the Driver would apply its own 300_000 default)
  # becomes the floor, an explicit lower value is raised to it, an explicit
  # higher value wins.
  @doc false
  @spec reviewer_progress_timeout(timeout() | nil) :: timeout()
  def reviewer_progress_timeout(nil), do: @reviewer_progress_floor
  def reviewer_progress_timeout(:infinity), do: :infinity
  def reviewer_progress_timeout(progress) when is_integer(progress), do: max(progress, @reviewer_progress_floor)

  # Floors the implementer-phase progress window. An implementer runs the same
  # silent check commands a reviewer does, so it is reachable by the identical
  # failure; the idle floors are symmetric across both phases for that reason
  # and these follow them.
  @doc false
  @spec implementer_progress_timeout(timeout() | nil) :: timeout()
  def implementer_progress_timeout(nil), do: @implementer_progress_floor
  def implementer_progress_timeout(:infinity), do: :infinity

  def implementer_progress_timeout(progress) when is_integer(progress), do: max(progress, @implementer_progress_floor)
end
