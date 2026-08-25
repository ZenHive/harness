defmodule Harness.RunLandingTriggerTest do
  @moduledoc """
  The settle-time landing trigger: an approved run under an `:auto` project with
  a `target_branch` enqueues exactly one landing job onto the serialized
  `landing_<name>` queue; a `:manual` project enqueues nothing.
  """
  # async: false because tests mutate ProjectRegistry and the :oban_insert app env seam.
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter
  alias Harness.Test.SettingsStoreMemory

  defp item, do: %Item{id: "42", title: "t", prompt: "p", agent: :claude, fingerprint: "fp-42"}

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

  describe "maybe_enqueue_landing on settle" do
    test "an approved :auto run enqueues a landing job on the serialized landing queue" do
      capture_inserts()
      repo = GitFixture.init_repo()

      project = %{
        ProjectFixture.from_repo(repo)
        | landing_policy: :auto,
          target_branch: "main"
      }

      run_id = start_run(project)
      assert %Result{state: :done, reason: :approved} = await_approved(run_id)

      assert_receive {:landing_insert, changeset}, 5_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["project_name"] == project.name
      assert args["task_id"] == "42"
      assert args["task_fingerprint"] == "fp-42"
      assert args["run_id"] == run_id
      assert args["agent"] == "claude"
      assert args["branch"] == "harness/" <> run_id
      assert args["land_attempt"] == 1
    end

    test "an approved :manual run enqueues nothing" do
      capture_inserts()
      repo = GitFixture.init_repo()

      project = %{
        ProjectFixture.from_repo(repo)
        | landing_policy: :manual,
          target_branch: "main"
      }

      run_id = start_run(project)
      assert %Result{state: :done, reason: :approved} = await_approved(run_id)

      refute_receive {:landing_insert, _changeset}, 500
    end

    test "a :manual-registered project flipped to :auto via the runtime override auto-lands through lookup (no per-call-site overlay)" do
      capture_inserts()
      repo = GitFixture.init_repo()
      SettingsStoreMemory.reset(scope: :test_default)

      project = %{ProjectFixture.from_repo(repo) | landing_policy: :manual, target_branch: nil}
      :ok = ProjectRegistry.register(project)

      on_exit(fn ->
        ProjectRegistry.unregister(project.name)
        SettingsStoreMemory.reset(scope: :test_default)
      end)

      :ok = LandingSettings.set(project.name, :auto, "main", "test")

      # The run trusts the *effective* project the registry hands it; run.ex does
      # not re-overlay. Resolving via lookup (as every real dispatch path does)
      # must therefore drive the auto-land enqueue off the persisted override.
      assert {:ok, %{landing_policy: :auto, target_branch: "main"} = effective} =
               ProjectRegistry.lookup(project.name)

      run_id = start_run(effective)
      assert %Result{state: :done, reason: :approved} = await_approved(run_id)

      assert_receive {:landing_insert, changeset}, 5_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name
    end
  end
end
