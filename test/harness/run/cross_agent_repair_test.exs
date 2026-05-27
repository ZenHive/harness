defmodule Harness.Run.CrossAgentRepairTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Verification.Check

  defmodule RecordingGrader do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{permission_modes: [:autonomous]}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{prompt: prompt, adapter_opts: opts}) do
      prompt_file = Keyword.fetch!(opts, :prompt_file)
      count_file = Keyword.fetch!(opts, :count_file)

      {:ok,
       {"/bin/sh",
        [
          "-c",
          """
          printf '%s' "$1" > "$2"
          printf 'hit\n' >> "$3"
          printf 'Repeated marker failure needs a different angle.\\n<<<VERDICT:REJECT>>>\\n'
          """,
          "recording-grader",
          prompt,
          prompt_file,
          count_file
        ], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  setup do
    old_config = Application.get_env(:harness, :cross_agent_repair)

    on_exit(fn ->
      case old_config do
        nil -> Application.delete_env(:harness, :cross_agent_repair)
        config -> Application.put_env(:harness, :cross_agent_repair, config)
      end
    end)

    :ok
  end

  test "same check failing twice with the same signature dispatches one cross-agent grader move" do
    prompt_file = tmp_path("cross-agent-prompt")
    count_file = tmp_path("cross-agent-count")

    Application.put_env(:harness, :cross_agent_repair,
      enabled: true,
      grader: RecordingGrader,
      adapter_opts: [prompt_file: prompt_file, count_file: count_file],
      total_timeout: 10_000,
      idle_timeout: 5_000
    )

    {run_id, pid, _repo} =
      start_repair(adapter_opts: [command: :repair_noop], checks: marker_checks(), max_repair_attempts: 2)

    result = await_result(run_id, pid)

    assert %Result{state: :failed, reason: :verification_red, repair_attempts: 2} = result
    assert File.read!(count_file) == "hit\n"

    prompt = File.read!(prompt_file)
    assert prompt =~ "Proposed approach"
    assert prompt =~ "Cost of guessing wrong"
    assert prompt =~ "Failing check evidence"
    assert prompt =~ "check: marker"
    assert prompt =~ "<<<VERDICT:APPROVE>>>"
    assert prompt =~ "<<<VERDICT:REJECT>>>"
  end

  test "disabled cross-agent repair keeps the existing same-agent repair loop behavior" do
    count_file = tmp_path("cross-agent-disabled-count")

    Application.put_env(:harness, :cross_agent_repair,
      enabled: false,
      grader: RecordingGrader,
      adapter_opts: [prompt_file: tmp_path("unused-prompt"), count_file: count_file]
    )

    {run_id, pid, _repo} =
      start_repair(adapter_opts: [command: :repair_noop], checks: marker_checks(), max_repair_attempts: 2)

    result = await_result(run_id, pid)

    assert %Result{state: :failed, reason: :verification_red, repair_attempts: 2} = result
    refute File.exists?(count_file)
  end

  defp start_repair(overrides) do
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo)
    base = GitFixture.tmp_base()

    opts =
      Keyword.merge(
        [
          base_dir: base,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
          terminal_linger: 100
        ],
        overrides
      )

    {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
    {run_id, pid, repo}
  end

  defp marker_checks, do: [check("ok", "true"), check("marker", "test", ["-f", "repair_marker"])]

  defp check(name, command, args \\ []), do: %Check{name: name, command: command, args: args}

  defp item do
    %Item{id: "59", title: "Cross-agent repair grader", prompt: "do the thing", agent: :claude}
  end

  defp await_result(run_id, pid) do
    ref = Process.monitor(pid)
    assert_receive {:harness_run, ^run_id, %Result{} = result}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
    result
  end

  defp tmp_path(prefix) do
    # Wall-clock nanoseconds keep the path unique across BEAM restarts, where
    # `System.unique_integer/1` resets to 1 and would otherwise reuse a count
    # file left behind by a crashed previous run — the flaky-test failure mode
    # ("hit\nhit\nhit\n" instead of "hit\n" because prior hits were never
    # cleaned up).
    suffix = "#{System.unique_integer([:positive])}-#{System.os_time(:nanosecond)}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end
end
