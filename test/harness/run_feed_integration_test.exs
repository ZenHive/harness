defmodule Harness.RunFeedIntegrationTest do
  # Proves the Harness.Run gen_statem emits fleet run-lifecycle broadcasts on
  # the RunFeed topic: at least one non-terminal update, then a settled message
  # carrying the terminal status. This is the wiring the event-driven dashboard
  # depends on.
  # async: false because it drives the shared Run supervisor/registry and PubSub topic.
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Testing.FakeAdapter
  alias Harness.Dashboard.RunFeed
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor

  test "a run broadcasts non-terminal updates then a terminal settled message" do
    :ok = RunFeed.subscribe()

    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo)

    {:ok, run_id, _pid} =
      RunSupervisor.start_run(
        %Item{id: "rf", title: "feed", prompt: "do the thing", agent: :claude},
        project,
        FakeAdapter,
        base_dir: base,
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100,
        subscriber: self()
      )

    assert_receive {:harness_run_update, %Status{run_id: ^run_id}}, 10_000
    assert_receive {:harness_run_settled, %Status{run_id: ^run_id, state: state}}, 15_000
    assert state in [:done, :failed]

    # The run also delivers its result to the subscriber; drain it so a lingering
    # gen_statem doesn't outlive the test.
    assert_receive {:harness_run, ^run_id, _result}, 5_000
    Run.cancel(run_id)
  end
end
