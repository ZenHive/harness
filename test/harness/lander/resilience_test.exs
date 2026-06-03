defmodule Harness.Lander.ResilienceTest do
  @moduledoc """
  The merge-train resilience router. `plan/2` is exercised exhaustively as a pure
  function (every outcome × {under-cap, at-cap}); `route/2`'s effects are checked
  through the `:oban_insert` capture seam and the live `ProjectRegistry`.
  """
  use ExUnit.Case, async: false

  alias Harness.Lander.Resilience
  alias Harness.Notification.Event
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Test.CaptureSink

  describe "plan/2 — pure routing (exhaustive over the outcome union)" do
    test "landed terminates ok at any attempt" do
      assert {:ok, {:landed, "sha"}} = Resilience.plan({:landed, "sha"}, 1)
      assert {:ok, {:landed, "sha"}} = Resilience.plan({:landed, "sha"}, 2)
    end

    test "skipped terminates ok — nothing to act on — at any attempt" do
      assert {:ok, {:skipped, :github_source}} = Resilience.plan({:skipped, :github_source}, 1)
      assert {:ok, {:skipped, :github_source}} = Resilience.plan({:skipped, :github_source}, 2)
    end

    test "error routes to retry (Oban backoff) at any attempt" do
      assert {:retry, :boom} = Resilience.plan({:error, :boom}, 1)
      assert {:retry, :boom} = Resilience.plan({:error, :boom}, 2)
    end

    test "conflict re-dispatches under the cap, blocks at it" do
      assert {:redispatch, 2, :conflict} = Resilience.plan({:conflict, "CONFLICT (content)"}, 1)
      assert {:block, :conflict} = Resilience.plan({:conflict, "CONFLICT (content)"}, 2)
    end

    test "push_rejected re-lands the retained branch under the cap, blocks at it" do
      assert {:reland, 2} = Resilience.plan({:push_rejected, "non-fast-forward"}, 1)
      assert {:block, :push_rejected} = Resilience.plan({:push_rejected, "non-fast-forward"}, 2)
    end

    test "reflex halts re-dispatch under the cap, block at it" do
      assert {:redispatch, 2, :reflex_halt} = Resilience.plan({:reflex_halt, :progress_stalled}, 1)
      assert {:block, :reflex_halt} = Resilience.plan({:reflex_halt, :progress_stalled}, 2)
    end

    test "blocked-command reflex halts block immediately" do
      assert {:block, :reflex_halt} = Resilience.plan({:reflex_halt, {:blocked_command, "mix deps.clean"}}, 1)
    end
  end

  describe "route/2 — terminal outcomes (no repair)" do
    test "landed returns :ok" do
      assert :ok = Resilience.route({:landed, "deadbeef"}, base_args("any", 1))
    end

    test "skipped returns :ok" do
      assert :ok = Resilience.route({:skipped, :github_source}, base_args("any", 1))
    end

    test "error returns {:error, reason} so Oban backs off and retries" do
      assert {:error, :fetch_boom} = Resilience.route({:error, :fetch_boom}, base_args("any", 1))
    end
  end

  describe "route/2 — reland effect (push_rejected under the cap)" do
    setup do
      project = register_project()
      capture_inserts()
      {:ok, project: project}
    end

    test "re-enqueues a landing job carrying land_attempt 2 on the serialized queue", %{project: project} do
      args = base_args(project.name, 1)

      assert :ok = Resilience.route({:push_rejected, "non-fast-forward"}, args)

      assert_receive {:landing_insert, changeset}, 1_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

      reland_args = Ecto.Changeset.get_field(changeset, :args)
      assert reland_args["land_attempt"] == 2
      assert reland_args["branch"] == args["branch"]
      assert reland_args["task_id"] == args["task_id"]
    end

    test "surfaces {:error, {:reland_failed, _}} when the re-insert fails", %{project: project} do
      Application.put_env(:harness, :oban_insert, fn _changeset -> {:error, :insert_boom} end)

      assert {:error, {:reland_failed, :insert_boom}} =
               Resilience.route({:push_rejected, "non-fast-forward"}, base_args(project.name, 1))
    end
  end

  describe "route/2 — block effect (cap exhausted)" do
    setup do
      project = register_project()
      capture_inserts()
      {:ok, project: project}
    end

    test "conflict at the cap cancels as blocked and enqueues nothing", %{project: project} do
      args = base_args(project.name, 2)

      assert {:cancel, {:blocked, reason}} = Resilience.route({:conflict, "CONFLICT (content)"}, args)
      assert reason =~ "land-cap exhausted after conflict"
      assert reason =~ "task " <> args["task_id"]

      refute_receive {:landing_insert, _changeset}, 300
    end

    test "push_rejected at the cap cancels as blocked (no reland)", %{project: project} do
      args = base_args(project.name, 2)

      assert {:cancel, {:blocked, reason}} = Resilience.route({:push_rejected, "non-fast-forward"}, args)
      assert reason =~ "land-cap exhausted after push_rejected"

      refute_receive {:landing_insert, _changeset}, 300
    end

    test "reflex halt at the cap cancels as blocked and notifies", %{project: project} do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      args = base_args(project.name, 2)

      assert {:cancel, {:blocked, reason}} = Resilience.route({:reflex_halt, :progress_stalled}, args)
      assert reason =~ "land-cap exhausted after reflex_halt"

      assert_receive {:notify, %Event{type: :blocked, task_id: "42", outcome: ^reason, land_attempt: 2}}
      refute_receive {:landing_insert, _changeset}, 300
    end
  end

  describe "route/2 — redispatch effect (failure paths)" do
    test "surfaces {:error, {:redispatch_failed, _}} when the project is unregistered" do
      args = base_args("ghost-#{System.unique_integer([:positive])}", 1)

      assert {:error, {:redispatch_failed, _reason}} = Resilience.route({:conflict, "CONFLICT"}, args)
    end

    test "surfaces {:error, {:redispatch_failed, {:unknown_adapter, _}}} for an unresolvable agent" do
      project = register_project()
      args = %{base_args(project.name, 1) | "agent" => "not-an-agent"}

      assert {:error, {:redispatch_failed, {:unknown_adapter, "not-an-agent"}}} =
               Resilience.route({:conflict, "CONFLICT (content)"}, args)
    end
  end

  describe "route/2 — witness notifications fire on the three transitions" do
    setup do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      :ok
    end

    test "a landed outcome notifies :landed with the SHA" do
      assert :ok = Resilience.route({:landed, "deadbeef"}, base_args("any", 1))

      assert_receive {:notify, %Event{type: :landed, task_id: "42", outcome: "deadbeef"}}
    end

    test "a cap-exhausted outcome notifies :blocked with the structured reason" do
      project = register_project()

      assert {:cancel, {:blocked, reason}} =
               Resilience.route({:push_rejected, "non-fast-forward"}, base_args(project.name, 2))

      assert_receive {:notify, %Event{type: :blocked, task_id: "42", outcome: ^reason, land_attempt: 2}}
    end
  end

  @spec register_project() :: Harness.Project.t()
  defp register_project do
    name = "resil-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo(Path.join(System.tmp_dir!(), name), name: name)
    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(name) end)
    project
  end

  @spec capture_inserts() :: :ok
  defp capture_inserts do
    test_pid = self()

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(test_pid, {:landing_insert, changeset})
      {:ok, %Oban.Job{}}
    end)

    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
    :ok
  end

  @spec base_args(String.t(), pos_integer()) :: map()
  defp base_args(project_name, attempt) do
    %{
      "project_name" => project_name,
      "run_id" => "run-x",
      "task_id" => "42",
      "agent" => "claude",
      "branch" => "harness/run-x",
      "land_attempt" => attempt
    }
  end
end
