defmodule Harness.StatusViewTest do
  use ExUnit.Case, async: false

  alias Harness.AgentRegistry
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.StatusView

  setup do
    AgentRegistry.reset()
    :ok
  end

  test "render/1 shows an empty fleet message when nothing is registered" do
    output = StatusView.render(%{runs: [], unavailable_agents: [], cron_polling: :disabled})

    assert output =~ "Harness fleet status"
    assert output =~ "Cron polling: disabled"
    assert output =~ "(no runs in flight or lingering)"
  end

  test "render/1 shows the next scheduled cron tick in the header" do
    output =
      StatusView.render(%{
        runs: [],
        unavailable_agents: [],
        cron_polling: {:enabled, "0 */2 * * *", ~U[2026-05-27 02:00:00Z]}
      })

    assert output =~ "Cron polling: next tick 2026-05-27 02:00:00Z (0 */2 * * *)"
  end

  test "classify/1 maps lifecycle states into the four buckets" do
    assert StatusView.classify(%Status{state: :running, run_id: "r", task_id: "1"}) == :in_flight

    assert StatusView.classify(%Status{state: :running, run_id: "r", task_id: "1", repair_attempts: 1}) ==
             :repairing

    assert StatusView.classify(%Status{state: :done, run_id: "r", task_id: "1"}) == :green
    assert StatusView.classify(%Status{state: :failed, run_id: "r", task_id: "1"}) == :red
  end

  test "render/1 groups runs into the four buckets with failure and availability detail" do
    snapshot = %{
      runs: [
        %{status: %Status{run_id: "run-a", task_id: "1", state: :running}, bucket: :in_flight, detail: nil},
        %{
          status: %Status{run_id: "run-b", task_id: "2", state: :running, repair_attempts: 1},
          bucket: :repairing,
          detail: "attempt 1"
        },
        %{status: %Status{run_id: "run-c", task_id: "3", state: :done}, bucket: :green, detail: nil},
        %{
          status: %Status{run_id: "run-d", task_id: "4", state: :failed, reason: :verification_red},
          bucket: :red,
          detail: "verification_red"
        }
      ],
      unavailable_agents: [{FakeAdapter, {:quota_exhausted, :exited}}],
      cron_polling: :disabled
    }

    output = StatusView.render(snapshot)

    assert output =~ "IN FLIGHT (1)"
    assert output =~ "task 1  run-a  running"
    assert output =~ "REPAIRING (1)"
    assert output =~ "task 2  run-b  running  attempt 1"
    assert output =~ "GREEN (1)"
    assert output =~ "task 3  run-c  done"
    assert output =~ "RED (1)"
    assert output =~ "task 4  run-d  failed  verification_red"
    assert output =~ "UNAVAILABLE AGENTS (1)"
    assert output =~ "FakeAdapter  quota exhausted (exited)"
  end

  test "snapshot/1 collects live registered runs" do
    run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)

    assert await_running(run_id)

    output = StatusView.render(StatusView.snapshot())

    assert output =~ "task 8  #{run_id}  running"

    assert :ok = Run.cancel(run_id)
  end

  defp start_run(overrides) do
    {item_id, overrides} = Keyword.pop(overrides, :item_id, "8")
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    project = ProjectFixture.from_repo(repo)

    opts =
      Keyword.merge(
        [
          base_dir: base,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
          terminal_linger: 100,
          max_repair_attempts: 0
        ],
        overrides
      )

    {:ok, run_id, _pid} = RunSupervisor.start_run(item(item_id), project, FakeAdapter, opts)
    run_id
  end

  defp item(id) do
    %Item{id: id, title: "Human status view", prompt: "do the thing", agent: :claude}
  end

  defp await_running(run_id, tries \\ 150)

  defp await_running(_run_id, 0), do: flunk("run never reached :running")

  defp await_running(run_id, tries) do
    case Run.status(run_id) do
      {:ok, %Status{state: :running}} ->
        :ok

      _ ->
        Process.sleep(20)
        await_running(run_id, tries - 1)
    end
  end
end
