defmodule Harness.Dashboard.RunsAPI do
  @moduledoc """
  `GET /harness/api/runs` — the live run roster as JSON, for operator-side
  scripts that must not restart the node while work is in flight.

  Oban is the wrong oracle for that question: a run's job is not the run.
  `dispatch-resume_failed` never had a job; a held run can outlive Lifeline's
  age bound (configured lifetime plus a five-minute margin); exhausted jobs are
  discarded rather than left `executing`. The run registry is the only source of
  truth, and this endpoint exposes it mechanically — every registered
  `Harness.Run` status, with `in_flight` counting the ones not yet settled.

  Unauthenticated like the rest of the dashboard: the standalone endpoint binds
  loopback only (see `Harness.Dashboard.Router`).
  """

  @behaviour Plug

  import Plug.Conn

  alias Harness.Run.Status
  alias Harness.StatusView

  @terminal_states [:done, :failed]

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    runs = Enum.map(StatusView.live_runs(), &row/1)
    in_flight = Enum.count(runs, &(&1.state not in @terminal_states))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{in_flight: in_flight, runs: runs}))
  end

  @spec row(StatusView.run_entry()) :: map()
  defp row(%{status: %Status{} = status}) do
    %{
      run_id: status.run_id,
      project: status.project_name,
      task_id: status.task_id,
      agent: status.agent,
      state: status.state,
      held: status.held?
    }
  end
end
