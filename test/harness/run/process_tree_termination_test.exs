defmodule Harness.Run.ProcessTreeTerminationTest do
  use Harness.RunCase, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Testing.FakeAdapter
  alias Harness.Test.IdentityFakeAdapter

  @grace_ms 50

  setup do
    previous = Application.get_env(:harness_agent_adapter, :run, [])
    Application.put_env(:harness_agent_adapter, :run, Keyword.put(previous, :terminate_grace_ms, @grace_ms))

    on_exit(fn -> Application.put_env(:harness_agent_adapter, :run, previous) end)
    :ok
  end

  describe "process-tree termination (Task 392)" do
    test "dispatch-cancel reaps a TERM-ignoring grandchild before settle" do
      file = grandchild_file()
      {run_id, pid} = start_tree_implementer(file)
      grandchild = await_pid_file(file)

      assert :ok = Run.cancel(run_id)
      assert %Result{state: :failed, reason: :cancelled} = await_result(run_id, pid)
      refute_os_alive(grandchild)
    end

    test "interrupt hold reaps a TERM-ignoring grandchild before :held" do
      file = grandchild_file()
      {run_id, _pid} = start_tree_implementer(file)
      grandchild = await_pid_file(file)

      assert :ok = Run.hold(run_id, true)
      await_held(run_id)
      refute_os_alive(grandchild)
    end

    test "lifetime expiry reaps a TERM-ignoring grandchild before worktree teardown" do
      file = grandchild_file()

      {run_id, pid} =
        start(
          adapter: __MODULE__.TreeAdapter,
          adapter_opts: [grandchild_file: file],
          lifetime_timeout: 400,
          terminal_linger: 100
        )

      grandchild = await_pid_file(file)
      assert %Result{state: :failed, reason: :timed_out} = await_result(run_id, pid)
      refute_os_alive(grandchild)
    end

    test "implementer idle timeout quiesces the grandchild before the reviewer reuses the worktree" do
      file = grandchild_file()

      {run_id, pid} =
        start(
          adapter: __MODULE__.TreeAdapter,
          adapter_opts: [grandchild_file: file],
          reviewer: __MODULE__.QuiescenceCheckReviewer,
          reviewer_adapter_opts: [grandchild_file: file, owner: self()],
          implementer_idle_timeout: 400,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      _grandchild = await_pid_file(file)
      assert_receive {:grandchild_alive_at_reuse?, false}, 8_000
      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid, 10_000)
    end

    test "Driver total timeout quiesces the grandchild before the reviewer reuses the worktree" do
      file = grandchild_file()

      {run_id, pid} =
        start(
          adapter: __MODULE__.TreeAdapter,
          adapter_opts: [grandchild_file: file],
          reviewer: __MODULE__.QuiescenceCheckReviewer,
          reviewer_adapter_opts: [grandchild_file: file, owner: self()],
          total_timeout: 400,
          implementer_idle_timeout: 30_000,
          idle_timeout: 30_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      _grandchild = await_pid_file(file)
      assert_receive {:grandchild_alive_at_reuse?, false}, 8_000
      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid, 10_000)
    end

    test "memory watchdog reaps a TERM-ignoring grandchild" do
      file = grandchild_file()

      {run_id, pid} =
        start(
          adapter: __MODULE__.TreeAdapter,
          adapter_opts: [grandchild_file: file],
          mem_threshold_kb: 1,
          mem_sample_interval: 200,
          implementer_idle_timeout: 30_000,
          idle_timeout: 30_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      grandchild = await_pid_file(file)
      assert %Result{state: :failed, reason: {:memory_runaway, _info}} = await_result(run_id, pid, 8_000)
      refute_os_alive(grandchild)
    end

    test "reviewer idle rotation quiesces the grandchild before the next reviewer spawns" do
      file = grandchild_file()

      {run_id, pid} =
        start(
          adapter_opts: [command: :write],
          reviewer: [__MODULE__.TreeAdapter, __MODULE__.QuiescenceCheckReviewer],
          reviewer_adapter_opts: [grandchild_file: file, owner: self()],
          reviewing_idle_timeout: 400,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      _grandchild = await_pid_file(file)
      assert_receive {:grandchild_alive_at_reuse?, false}, 8_000

      assert %Result{state: :done, reason: :approved, reviewer_rotation_count: 1} =
               await_result(run_id, pid, 10_000)
    end
  end

  defmodule TreeAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{adapter_opts: opts}) do
      file = Keyword.fetch!(opts, :grandchild_file)

      child_script = """
      trap '' TERM
      sh -c 'echo $$ > #{file}; trap "" TERM; while :; do :; done' &
      wait
      """

      root_script = """
      sh -c "$1" &
      wait
      """

      {:ok, {"/bin/sh", ["-c", root_script, "harness-tree", child_script], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  defmodule QuiescenceCheckReviewer do
    @moduledoc false
    use Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{adapter_opts: opts, env: env}) do
      file = Keyword.fetch!(opts, :grandchild_file)
      owner = Keyword.fetch!(opts, :owner)
      pid = file |> File.read!() |> String.trim() |> String.to_integer()
      send(owner, {:grandchild_alive_at_reuse?, os_alive?(pid)})

      json =
        %{
          "verdict" => "approve",
          "report" => FakeAdapter.review_report("approve"),
          "ratings" => FakeAdapter.review_ratings()
        }
        |> IdentityFakeAdapter.bind_fields(env)
        |> Jason.encode!()

      script = ~S(mkdir -p .harness; printf '%s' "$1" > .harness/review.json)
      {:ok, {"/bin/sh", ["-c", script, "harness-fake", json], Map.to_list(env)}}
    end

    @spec os_alive?(non_neg_integer()) :: boolean()
    defp os_alive?(os_pid) do
      {_output, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      code == 0
    end
  end

  defp start_tree_implementer(file) do
    start(
      adapter: __MODULE__.TreeAdapter,
      adapter_opts: [grandchild_file: file],
      lifetime_timeout: 30_000,
      terminal_linger: 100
    )
  end

  defp grandchild_file do
    path = Path.join(System.tmp_dir!(), "harness-tree-#{System.unique_integer([:positive])}.pid")
    on_exit(fn -> reap_pid_file(path) end)
    path
  end

  defp reap_pid_file(path) do
    with {:ok, contents} <- File.read(path),
         {pid, ""} <- Integer.parse(String.trim(contents)) do
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    else
      _missing -> :ok
    end

    File.rm(path)
  end

  defp refute_os_alive(pid) do
    {_output, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert code != 0, "expected pid #{pid} to be dead once termination returned"
  end
end
