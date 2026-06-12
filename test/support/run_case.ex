defmodule Harness.RunCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  # path (the gen_statem must survive a crashing step task).
  defmodule CrashingAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: raise("boom in build_command")

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter that pollutes the main checkout before crashing in build_command/1.
  # Drives the post-Task-229 cleanup path: witnessed checkout pollution should
  # route through recovery even when the immediate driver task dies.
  defmodule PollutingCrashAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{adapter_opts: opts}) do
      repo = Keyword.fetch!(opts, :repo)
      File.write!(Path.join(repo, "leaked.txt"), "leaked\n")
      raise("polluted checkout before crashing")
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter whose build_command/1 blocks forever — the agent never spawns,
  # so {:run_handle, _} never arrives. Drives the lifetime-timeout
  # force-settle path: the budget must still fire even with `agent_run: nil`.
  defmodule HangingAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation) do
      Process.sleep(:infinity)
      {:ok, {"/bin/true", [], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter whose first invocation builds a command that cannot spawn, then
  # builds a real command on the second attempt. This exercises run-local
  # substrate retry before the lifecycle can settle agent_spawn_failed.
  defmodule TransientSpawnAdapter do
    @moduledoc false
    use Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      counter = Keyword.fetch!(opts, :counter)
      attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

      if attempt == 1 do
        {:ok, {"definitely-not-a-real-binary-xyz", [], []}}
      else
        {:ok, {"/bin/sh", ["-c", "printf agent-work > delivery.txt"], []}}
      end
    end
  end

  # A reviewer double that spawns a real, long-lived process — its handle fires,
  # then it goes silent — to drive the reviewer idle-timeout rotation path
  # (Task 228).
  defmodule SpawnThenIdleReviewer do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: {:ok, {"/bin/sleep", ["30"], []}}

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  # An adapter that spawns a real agent but declares session_resume: false —
  # drives the steer-unsupported path.
  defmodule NoResumeAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: false}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}), do: {:ok, {"/bin/sleep", ["30"], []}}

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  # An adapter that spawns a real, long-lived agent, then crashes the driver
  # task on the agent's first output — a driver crash *after* the agent's OS
  # process exists, which the run must SIGKILL rather than orphan.
  defmodule DriverCrashAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      pid_file = Keyword.fetch!(opts, :pid_file)
      # Record the agent's own pid, emit a line so the driver calls
      # classify_message, then stay alive long enough to be orphaned.
      {:ok, {"/bin/sh", ["-c", "echo $$ > #{pid_file}; echo go; exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({_port, {:data, _data}}, _run), do: raise("crash the driver after the agent spawned")

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  # A real, long-lived agent that records its own pid and otherwise idles — lets
  # a test capture the spawned os_pid and assert terminate/1 reaped it on a
  # cancel/lifetime/fail path (Task 201).
  defmodule PidFileAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      pid_file = Keyword.fetch!(opts, :pid_file)
      {:ok, {"/bin/sh", ["-c", "echo $$ > #{pid_file}; exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run), do: OSProcess.kill(run)
  end

  defmodule ReportingTerminateAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.OSProcess

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%{adapter_opts: opts}) do
      owner = Keyword.fetch!(opts, :owner)
      Application.put_env(:harness, :terminate_report_owner, owner)
      {:ok, {"/bin/sh", ["-c", "exec sleep 30"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(run) do
      owner = Application.fetch_env!(:harness, :terminate_report_owner)
      send(owner, {:terminated_with_live_port?, Port.info(run.port, :os_pid) != nil})
      OSProcess.kill(run)
    end
  end

  using do
    # A test-suite template injects helpers — the long quote block is intrinsic,
    # as it is for ExUnit.CaseTemplate and Phoenix's *Case modules.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      import ExUnit.CaptureLog

      alias Harness.Agent.Settings, as: AgentSettings
      alias Harness.AgentAdapter.Antigravity
      alias Harness.AgentAdapter.Codex
      alias Harness.AgentAdapter.Outcome
      alias Harness.Dashboard.RunFeed
      alias Harness.Dashboard.Transcript
      alias Harness.Dashboard.Transcript.Parser
      alias Harness.FakeAdapter
      alias Harness.FakeModelAdapter
      alias Harness.GitFixture
      alias Harness.Landing.Settings, as: LandingSettings
      alias Harness.ProcessFixture
      alias Harness.ProjectFixture
      alias Harness.ProjectRegistry
      alias Harness.ResultStore
      alias Harness.Roadmap.Item
      alias Harness.Run
      alias Harness.Run.Result
      alias Harness.Run.Review
      alias Harness.Run.Status
      alias Harness.RunCase.CrashingAdapter
      alias Harness.RunCase.DriverCrashAdapter
      alias Harness.RunCase.HangingAdapter
      alias Harness.RunCase.NoResumeAdapter
      alias Harness.RunCase.PidFileAdapter
      alias Harness.RunCase.PollutingCrashAdapter
      alias Harness.RunCase.ReportingTerminateAdapter
      alias Harness.RunCase.SpawnThenIdleReviewer
      alias Harness.RunCase.TransientSpawnAdapter
      alias Harness.Test.CaptureSink
      alias Harness.Test.SettingsStoreMemory
      alias Harness.TokenUsage
      alias Harness.Worktree

      @executable_mode 0o755
      defp install_agent_kind(pid, kind) do
        :sys.replace_state(pid, fn
          {state, data} when is_atom(state) and is_map(data) ->
            {state, %{data | agent_kind: kind, transcript_parser_state: Parser.init_state(kind)}}
        end)

        _ = Antigravity
        :ok
      end

      # ── helpers ─────────────────────────────────────────────────────────────

      defp run(overrides) do
        {run_id, pid} = start(overrides)
        await_result(run_id, pid)
      end

      defp start(overrides) do
        {project, overrides} = Keyword.pop(overrides, :project)
        project = project || ProjectFixture.from_repo(GitFixture.init_repo())
        start_with_project(project, overrides)
      end

      defp start_with_project(project, overrides) do
        base = GitFixture.tmp_base()
        {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)
        {item, overrides} = Keyword.pop(overrides, :item, item())
        explicit_model? = Keyword.has_key?(overrides, :requested_model)

        opts =
          base |> default_opts() |> Keyword.merge(overrides) |> maybe_suppress_configured_model(adapter, explicit_model?)

        {:ok, run_id, pid} = Run.Supervisor.start_run(item, project, adapter, opts)
        {run_id, pid}
      end

      defp start_with_project_reviewer(project, overrides) do
        base = GitFixture.tmp_base()
        {adapter, overrides} = Keyword.pop(overrides, :adapter, FakeAdapter)
        explicit_model? = Keyword.has_key?(overrides, :requested_model)

        opts =
          base
          |> default_opts()
          |> Keyword.delete(:reviewer)
          |> Keyword.merge(overrides)
          |> maybe_suppress_configured_model(adapter, explicit_model?)

        {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, adapter, opts)
        {run_id, pid}
      end

      defp maybe_suppress_configured_model(opts, adapter, explicit_model?) do
        cond do
          explicit_model? -> opts
          adapter.capabilities().model_families == [] -> opts
          true -> Keyword.delete(opts, :requested_model)
        end
      end

      # Every run goes through the reviewer gate, so the defaults wire FakeAdapter
      # as both implementer (:write) and reviewer ({:review, "approve"} — a clean
      # approve). FakeAdapter is unregistered, so the cross-family constraint never
      # trips for test doubles.
      defp default_opts(base) do
        [
          base_dir: base,
          adapter_opts: [command: :write],
          reviewer: FakeAdapter,
          reviewer_adapter_opts: [command: {:review, "approve"}],
          requested_model: nil,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        ]
      end

      defp item do
        %Item{id: "8", title: "Supervised run lifecycle", prompt: "do the thing", agent: :claude}
      end

      defp fake_codex_bin do
        dir = Path.join(System.tmp_dir!(), "harness-fake-codex-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        path = Path.join(dir, "codex")
        json = Jason.encode!(%{verdict: "approve", report: "fake review: approve", ratings: FakeAdapter.review_ratings()})

        File.write!(path, """
        #!/bin/sh
        mkdir -p .harness
        printf '%s' '#{json}' > .harness/review.json
        """)

        File.chmod!(path, @executable_mode)
        dir
      end

      defp fake_rmap_dir do
        dir = Path.join(System.tmp_dir!(), "harness-fake-rmap-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        path = Path.join(dir, "rmap")
        File.write!(path, "#!/bin/sh\necho fake-rmap\n")
        File.chmod!(path, @executable_mode)
        dir
      end

      defp with_rmap_path_dirs(dirs) do
        prior = Application.get_env(:harness, :rmap_path_dirs)
        Application.put_env(:harness, :rmap_path_dirs, dirs)

        on_exit(fn ->
          if prior,
            do: Application.put_env(:harness, :rmap_path_dirs, prior),
            else: Application.delete_env(:harness, :rmap_path_dirs)
        end)
      end

      defp prepend_path(dir) do
        prior = System.get_env("PATH", "")
        System.put_env("PATH", dir <> ":" <> prior)
        on_exit(fn -> System.put_env("PATH", prior) end)
      end

      # Sets the per-agent :agent_model app-env override for the test and restores the
      # prior value (or deletes the key) on exit — the configured-model fixtures.
      defp put_agent_model_env(kw) do
        lock_model_env()
        prior = Application.get_env(:harness, :agent_model)
        Application.put_env(:harness, :agent_model, kw)

        on_exit(fn ->
          if prior,
            do: Application.put_env(:harness, :agent_model, prior),
            else: Application.delete_env(:harness, :agent_model)
        end)
      end

      defp put_reviewer_model_env(kw) do
        lock_model_env()
        prior = Application.get_env(:harness, :reviewer_model)
        Application.put_env(:harness, :reviewer_model, kw)

        on_exit(fn ->
          if prior,
            do: Application.put_env(:harness, :reviewer_model, prior),
            else: Application.delete_env(:harness, :reviewer_model)
        end)
      end

      defp lock_model_env do
        if !Process.get(:harness_run_case_model_env_lock?) do
          :global.set_lock({{:harness, :run_case_model_env}, self()})
          Process.put(:harness_run_case_model_env_lock?, true)
          on_exit(fn -> :global.del_lock({{:harness, :run_case_model_env}, self()}) end)
        end
      end

      defp await_result(run_id, pid, timeout \\ 10_000) do
        ref = Process.monitor(pid)
        assert_receive {:harness_run, ^run_id, %Result{} = result}, timeout
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
        result
      end

      defp await_agent_os_pid(run_id, tries \\ 150)

      defp await_agent_os_pid(_run_id, 0), do: flunk("run never reported an agent os_pid")

      defp await_agent_os_pid(run_id, tries) do
        case Run.status(run_id) do
          {:ok, %Status{state: :running, agent_os_pid: os_pid}} when is_integer(os_pid) ->
            os_pid

          _other ->
            Process.sleep(20)
            await_agent_os_pid(run_id, tries - 1)
        end
      end

      # Polls `Run.status/1` until the run reports `state: :running` (worktree
      # carved, agent task spawned), regardless of whether an agent has yet been
      # observed. Used by the cancel-before-handle regression to anchor the cancel
      # at a point where `agent_run` is still nil so the cancel must be deferred.
      defp wait_until_running(run_id), do: wait_until_running(run_id, 20, 2_000)

      defp wait_until_running(run_id, interval_ms, total_ms) when total_ms > 0 do
        case Run.status(run_id) do
          {:ok, %Status{state: :running}} ->
            :ok

          _other ->
            Process.sleep(interval_ms)
            wait_until_running(run_id, interval_ms, total_ms - interval_ms)
        end
      end

      defp wait_until_running(_run_id, _interval_ms, _total_ms), do: flunk("run never reached state: :running")

      defp await_held(run_id, tries \\ 150)

      defp await_held(_run_id, 0), do: flunk("run never reached state: :held")

      defp await_held(run_id, tries) do
        case Run.status(run_id) do
          {:ok, %Status{state: :held}} ->
            :ok

          _other ->
            Process.sleep(20)
            await_held(run_id, tries - 1)
        end
      end

      defp await_pid_file(path, tries \\ 200)

      defp await_pid_file(_path, 0), do: flunk("agent never wrote its pid file")

      defp await_pid_file(path, tries) do
        with {:ok, content} <- File.read(path),
             {os_pid, _rest} <- Integer.parse(String.trim(content)) do
          os_pid
        else
          _ ->
            Process.sleep(20)
            await_pid_file(path, tries - 1)
        end
      end

      defp file_store do
        {Harness.ResultStore.Memory,
         root:
           Path.join(
             System.tmp_dir!(),
             "harness-result-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
           )}
      end
    end
  end
end
