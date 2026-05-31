defmodule Harness.Run.SemanticGateTest do
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

  defmodule RecordingSemanticGrader do
    @moduledoc false

    use Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{permission_modes: [:autonomous]}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{prompt: prompt, adapter_opts: opts}) do
      prompt_file = Keyword.fetch!(opts, :prompt_file)
      count_file = Keyword.fetch!(opts, :count_file)
      mode = opts |> Keyword.fetch!(:mode) |> Atom.to_string()

      {:ok,
       {"/bin/sh",
        [
          "-c",
          """
          printf '%s' "$1" > "$2"
          count=$(cat "$3" 2>/dev/null | wc -l | tr -d ' ')
          printf 'hit\\n' >> "$3"
          case "$4" in
            approve)
              printf 'semantic match\\n<<<VERDICT:APPROVE>>>\\n'
              ;;
            reject)
              printf 'semantic mismatch\\n<<<VERDICT:REJECT>>>\\n'
              ;;
            reject_then_approve)
              if [ "$count" = "0" ]; then
                printf 'first pass missed the contract\\n<<<VERDICT:REJECT>>>\\n'
              else
                printf 'repair now matches the contract\\n<<<VERDICT:APPROVE>>>\\n'
              fi
              ;;
          esac
          """,
          "semantic-grader",
          prompt,
          prompt_file,
          count_file,
          mode
        ], []}}
    end
  end

  describe "green semantic gate" do
    test "green verdict with gate enabled dispatches a grader with task contract and committed diff" do
      prompt_file = tmp_path("semantic-gate-prompt")
      count_file = tmp_path("semantic-gate-count")

      result =
        run(
          item: item(),
          semantic_gate: [
            enabled: true,
            grader: RecordingSemanticGrader,
            adapter_opts: [prompt_file: prompt_file, count_file: count_file, mode: :approve],
            total_timeout: 10_000,
            idle_timeout: 5_000
          ]
        )

      assert %Result{state: :done, reason: :passed, repair_attempts: 0} = result
      assert File.read!(count_file) == "hit\n"

      prompt = File.read!(prompt_file)
      assert prompt =~ "Task body:"
      assert prompt =~ "Build the smallest useful thing."
      assert prompt =~ "Acceptance criteria:"
      assert prompt =~ "- preserve the hard case"
      assert prompt =~ "Committed diff:"
      assert prompt =~ "agent_output.txt"
      assert prompt =~ "<<<VERDICT:APPROVE>>>"
      assert prompt =~ "<<<VERDICT:REJECT>>>"
    end

    test "reject blocks done, feeds one repair pass, and approve settles done" do
      prompt_file = tmp_path("semantic-repair-prompt")
      count_file = tmp_path("semantic-repair-count")

      {run_id, pid, repo} =
        start(
          item: item(),
          adapter_opts: [command: :repair],
          max_repair_attempts: 1,
          semantic_gate: [
            enabled: true,
            grader: RecordingSemanticGrader,
            adapter_opts: [
              prompt_file: prompt_file,
              count_file: count_file,
              mode: :reject_then_approve
            ],
            total_timeout: 10_000,
            idle_timeout: 5_000
          ]
        )

      result = await_result(run_id, pid, 10_000)

      assert %Result{state: :done, reason: :passed, repair_attempts: 1} = result
      assert File.read!(count_file) == "hit\nhit\n"

      marker = GitFixture.git!(repo, ["show", "harness/#{run_id}:repair_marker"])
      assert marker =~ "semantic gate rejected"
      assert marker =~ "first pass missed the contract"
    end

    test "dispatch failure is treated as semantic rejection" do
      result =
        run(
          semantic_gate: [
            enabled: true,
            grader: FakeAdapter,
            adapter_opts: [command: :missing],
            total_timeout: 10_000,
            idle_timeout: 5_000
          ]
        )

      assert %Result{state: :failed, reason: :semantic_rejection, repair_attempts: 0} = result
    end

    test "timeout without an approve sentinel is treated as semantic rejection" do
      result =
        run(
          semantic_gate: [
            enabled: true,
            grader: FakeAdapter,
            adapter_opts: [command: :sleep],
            total_timeout: 10_000,
            idle_timeout: 150
          ]
        )

      assert %Result{state: :failed, reason: :semantic_rejection, repair_attempts: 0} = result
    end

    test "explicit same-family grader is rejected fail-safe" do
      result =
        run(
          semantic_gate: [
            enabled: true,
            grader: :claude
          ]
        )

      assert %Result{state: :failed, reason: :semantic_rejection, repair_attempts: 0} = result
    end

    test "gate is off by default, auto-enabled for auto-landing projects, and skippable" do
      prompt_file = tmp_path("semantic-auto-prompt")
      count_file = tmp_path("semantic-auto-count")

      manual_project = project(landing_policy: :manual)

      assert %Result{state: :done, reason: :passed} =
               run(
                 project: manual_project,
                 semantic_gate: [
                   enabled: :auto,
                   grader: RecordingSemanticGrader,
                   adapter_opts: [
                     prompt_file: prompt_file,
                     count_file: count_file,
                     mode: :approve
                   ]
                 ]
               )

      refute File.exists?(count_file)

      auto_project = project(landing_policy: :auto)

      assert %Result{state: :done, reason: :passed} =
               run(
                 project: auto_project,
                 semantic_gate: [
                   enabled: :auto,
                   grader: RecordingSemanticGrader,
                   adapter_opts: [
                     prompt_file: prompt_file,
                     count_file: count_file,
                     mode: :approve
                   ],
                   total_timeout: 10_000,
                   idle_timeout: 5_000
                 ]
               )

      assert File.read!(count_file) == "hit\n"

      assert %Result{state: :done, reason: :passed} =
               run(
                 project: auto_project,
                 semantic_gate: [
                   enabled: false,
                   grader: RecordingSemanticGrader,
                   adapter_opts: [
                     prompt_file: prompt_file,
                     count_file: count_file,
                     mode: :approve
                   ]
                 ]
               )

      assert File.read!(count_file) == "hit\n"
    end
  end

  describe "project-level semantic_gate mode (decoupled from auto-land — Task 123)" do
    test "project :always enables the gate for a manual-landing project (enabled: :auto)" do
      prompt_file = tmp_path("semantic-always-manual-prompt")
      count_file = tmp_path("semantic-always-manual-count")

      manual_always = project(landing_policy: :manual, semantic_gate: :always)

      assert %Result{state: :done, reason: :passed, repair_attempts: 0} =
               run(
                 project: manual_always,
                 semantic_gate: [
                   enabled: :auto,
                   grader: RecordingSemanticGrader,
                   adapter_opts: [prompt_file: prompt_file, count_file: count_file, mode: :approve],
                   total_timeout: 10_000,
                   idle_timeout: 5_000
                 ]
               )

      assert File.read!(count_file) == "hit\n"
    end

    test "project :always routes a REJECT into the repair loop under manual landing" do
      prompt_file = tmp_path("semantic-always-reject-prompt")
      count_file = tmp_path("semantic-always-reject-count")

      {run_id, pid, repo} =
        start(
          project_semantic_gate: :always,
          adapter_opts: [command: :repair],
          max_repair_attempts: 1,
          semantic_gate: [
            enabled: :auto,
            grader: RecordingSemanticGrader,
            adapter_opts: [
              prompt_file: prompt_file,
              count_file: count_file,
              mode: :reject_then_approve
            ],
            total_timeout: 10_000,
            idle_timeout: 5_000
          ]
        )

      result = await_result(run_id, pid, 10_000)

      assert %Result{state: :done, reason: :passed, repair_attempts: 1} = result
      assert File.read!(count_file) == "hit\nhit\n"

      marker = GitFixture.git!(repo, ["show", "harness/#{run_id}:repair_marker"])
      assert marker =~ "semantic gate rejected"
      assert marker =~ "first pass missed the contract"
    end

    test "project :off keeps the gate off even when auto-landing (enabled: :auto)" do
      prompt_file = tmp_path("semantic-off-auto-prompt")
      count_file = tmp_path("semantic-off-auto-count")

      auto_off = project(landing_policy: :auto, semantic_gate: :off)

      assert %Result{state: :done, reason: :passed} =
               run(
                 project: auto_off,
                 semantic_gate: [
                   enabled: :auto,
                   grader: RecordingSemanticGrader,
                   adapter_opts: [prompt_file: prompt_file, count_file: count_file, mode: :approve]
                 ]
               )

      refute File.exists?(count_file)
    end
  end

  defp run(overrides) do
    {run_id, pid, _repo} = start(overrides)
    await_result(run_id, pid, 10_000)
  end

  defp start(overrides) do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    # `:project_semantic_gate` sets the gate mode on the default project while
    # keeping it rooted at the repo `start/1` returns, so a test can both shape
    # the project-level gate AND read the run's `harness/<run_id>` branch.
    {gate_mode, overrides} = Keyword.pop(overrides, :project_semantic_gate, :auto_land_only)
    {project, overrides} = Keyword.pop(overrides, :project, project(repo: repo, semantic_gate: gate_mode))
    {item, overrides} = Keyword.pop(overrides, :item, item())

    opts =
      Keyword.merge(
        [
          base_dir: base,
          adapter_opts: [command: :write],
          checks: [check("ok", "true")],
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
          terminal_linger: 100,
          max_repair_attempts: 0
        ],
        overrides
      )

    {:ok, run_id, pid} = Run.Supervisor.start_run(item, project, FakeAdapter, opts)
    {run_id, pid, repo}
  end

  defp project(opts) do
    repo = Keyword.get_lazy(opts, :repo, fn -> GitFixture.init_repo() end)

    ProjectFixture.from_repo(repo, Keyword.take(opts, [:landing_policy, :semantic_gate]))
  end

  defp item do
    %Item{
      id: "99",
      title: "Semantic gate",
      prompt: "do the thing",
      agent: :claude,
      body: "Build the smallest useful thing.",
      acceptance_criteria: ["preserve the hard case", "do not solve the adjacent problem"]
    }
  end

  defp check(name, command, args \\ []), do: %Check{name: name, command: command, args: args}

  defp await_result(run_id, pid, timeout) do
    ref = Process.monitor(pid)
    assert_receive {:harness_run, ^run_id, %Result{} = result}, timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    result
  end

  defp tmp_path(prefix) do
    suffix = "#{System.unique_integer([:positive])}-#{System.os_time(:nanosecond)}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end
end
