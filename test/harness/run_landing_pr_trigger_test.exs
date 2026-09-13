defmodule Harness.RunLandingPRTriggerTest do
  @moduledoc """
  Settle-time landing trigger for `landing_policy: :pr`: an approved run with a
  `target_branch` enqueues the serialized `landing_<name>` job (same queue as
  `:auto`) and threads PR metadata onto the args.
  """
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  defp item do
    %Item{
      id: "42",
      title: "open a PR",
      prompt: "p",
      agent: :claude,
      body: "task body",
      acceptance_criteria: ["opens a PR"],
      fingerprint: "fp-42"
    }
  end

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
      reviewer: FakeAdapter,
      reviewer_adapter_opts: [command: {:review, "approve"}],
      result_store: nil,
      total_timeout: 30_000,
      idle_timeout: 10_000,
      lifetime_timeout: 30_000,
      terminal_linger: 100
    ]

    {:ok, run_id, _pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
    run_id
  end

  defp await_approved(run_id) do
    receive do
      {:harness_run, ^run_id, %Result{} = result} -> result
    after
      30_000 -> flunk("run #{run_id} did not settle")
    end
  end

  test "an approved :pr run enqueues a landing job with PR metadata" do
    capture_inserts()
    repo = GitFixture.init_repo()

    project = %{
      ProjectFixture.from_repo(repo)
      | landing_policy: :pr,
        target_branch: "main"
    }

    run_id = start_run(project)
    assert %Result{state: :done, reason: :approved} = await_approved(run_id)

    assert_receive {:landing_insert, changeset}, 5_000
    assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

    args = Ecto.Changeset.get_field(changeset, :args)
    assert args["project_name"] == project.name
    assert args["task_id"] == "42"
    assert args["branch"] == "harness/" <> run_id
    assert args["task_title"] == "open a PR"
    assert args["task_body"] == "task body"
    assert args["acceptance_criteria"] == ["opens a PR"]
    assert is_binary(args["review_report"])
  end
end
