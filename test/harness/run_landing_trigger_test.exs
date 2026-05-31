defmodule Harness.RunLandingTriggerTest do
  @moduledoc """
  The settle-time landing trigger: a green run under an `:auto` project with a
  `target_branch` enqueues exactly one landing job onto the serialized
  `landing_<name>` queue; a `:manual` project enqueues nothing.
  """
  use ExUnit.Case, async: false

  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Verification.Check

  defp item, do: %Item{id: "42", title: "t", prompt: "p", agent: :claude}

  defp capture_inserts do
    test_pid = self()

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(test_pid, {:landing_insert, changeset})
      {:ok, %Oban.Job{}}
    end)

    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
  end

  defp start_run(project) do
    base = GitFixture.tmp_base()

    opts = [
      subscriber: self(),
      base_dir: base,
      adapter_opts: [command: :write],
      checks: [%Check{name: "ok", command: "true", args: []}],
      result_store: nil,
      semantic_gate: [enabled: false],
      total_timeout: 30_000,
      idle_timeout: 10_000,
      lifetime_timeout: 30_000,
      verification_timeout: 10_000,
      terminal_linger: 100,
      max_repair_attempts: 0
    ]

    {:ok, run_id, _pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
    run_id
  end

  defp await_passed(run_id) do
    receive do
      {:harness_run, ^run_id, %Result{} = result} -> result
    after
      30_000 -> flunk("run #{run_id} did not settle")
    end
  end

  describe "maybe_enqueue_landing on settle" do
    test "a green :auto run enqueues a landing job on the serialized landing queue" do
      capture_inserts()
      repo = GitFixture.init_repo()

      project = %{
        ProjectFixture.from_repo(repo)
        | landing_policy: :auto,
          target_branch: "main"
      }

      run_id = start_run(project)
      assert %Result{state: :done, reason: :passed} = await_passed(run_id)

      assert_receive {:landing_insert, changeset}, 5_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["project_name"] == project.name
      assert args["task_id"] == "42"
      assert args["run_id"] == run_id
      assert args["agent"] == "claude"
      assert args["branch"] == "harness/" <> run_id
      assert args["land_attempt"] == 1
    end

    test "a green :manual run enqueues nothing" do
      capture_inserts()
      repo = GitFixture.init_repo()

      project = %{
        ProjectFixture.from_repo(repo)
        | landing_policy: :manual,
          target_branch: "main"
      }

      run_id = start_run(project)
      assert %Result{state: :done, reason: :passed} = await_passed(run_id)

      refute_receive {:landing_insert, _changeset}, 500
    end
  end
end
