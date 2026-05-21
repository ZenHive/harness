defmodule Harness.AgentAdapter.ConformanceCase do
  @moduledoc """
  The reusable conformance suite every `Harness.AgentAdapter` must pass.

  `use` it with the adapter under test — the whole suite is injected into the
  calling module:

      defmodule Harness.AgentAdapter.ClaudeConformanceTest do
        use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Claude
      end

  ## What it proves

  An adapter contributes four callbacks to the otherwise-generic run machinery
  (`Harness.AgentAdapter.invoke/2`, `Harness.AgentAdapter.Driver`). This suite
  pins the contract those callbacks must satisfy, across the five concerns the
  machinery depends on:

    * **Invocation** — `c:Harness.AgentAdapter.build_command/1` returns a
      spawnable `{executable, argv, env}` for the autonomous baseline and for
      every permission mode the adapter declares, and rejects an undeclared mode
      rather than falling back silently.
    * **Raw-output capture** — `c:Harness.AgentAdapter.classify_message/2` maps a
      port data chunk to `{:output, bytes, run}` with the bytes **verbatim**:
      harness passes agent output through unparsed.
    * **Termination detection** — an `:exit_status` message maps to
      `{:terminated, run, status}`, carrying the exit code without judging it.
    * **Timeout** — when a driver-shaped receive loop abandons a run at its
      deadline, the adapter's `c:Harness.AgentAdapter.terminate/1` reaps the OS
      process. (The driver's own deadline *enforcement* is generic and tested in
      `Harness.AgentAdapter.DriverTest`; this is its adapter-scoped half.)
    * **Adapter-level cancellation** — `terminate/1` kills an in-flight run,
      releases its port, and is idempotent.

  External cancellation *orchestration* — a caller telling the running system to
  cancel a job — is the supervised lifecycle's concern (`Harness.Run`) and is
  out of scope here.

  ## Agent-free by design

  The contract tests never spawn the real coding agent. `classify_message/2` is
  exercised with synthesized port messages; `terminate/1` and the timeout path
  with a throwaway `/bin/sleep` standing in for the agent's OS process — an
  adapter's `classify_message/2` / `terminate/1` are agent-agnostic (they match
  port messages and delegate to `Harness.AgentAdapter.OSProcess`), so a stand-in
  port is a faithful exercise. One `:integration`-tagged test drives the real
  agent end to end through `Harness.AgentAdapter.Driver.run/3`; it `flunk`s with
  install instructions when the agent binary is absent.

  ## The gate

  This is the gate Codex and every later adapter (Cursor, Grok, ACP) are held
  to. A leak it catches is fixed in `Harness.AgentAdapter` — the behaviour —
  never patched around in the adapter.
  """

  @doc false
  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    # A test-suite template injects an entire suite — the long quote block is
    # intrinsic, as it is for ExUnit.CaseTemplate and Phoenix's *Case modules.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [adapter: adapter] do
      use ExUnit.Case, async: true

      alias Harness.AgentAdapter.Capabilities
      alias Harness.AgentAdapter.Driver
      alias Harness.AgentAdapter.Invocation
      alias Harness.AgentAdapter.Outcome
      alias Harness.AgentAdapter.Run
      alias Harness.GitFixture
      alias Harness.ProcessFixture

      @adapter adapter

      # A baseline run request; `attrs` overrides any field for a specific case.
      @spec invocation(keyword()) :: Invocation.t()
      defp invocation(attrs \\ []) do
        struct!(
          %Invocation{prompt: "conformance probe", cwd: System.tmp_dir!(), task_id: "conformance"},
          attrs
        )
      end

      # A run handle bound to `port` — built directly the way invoke/2 builds it,
      # so the adapter's classify_message/2 and terminate/1 can be exercised
      # without spawning the real agent.
      @spec conformance_run(port(), non_neg_integer() | nil) :: Run.t()
      defp conformance_run(port, os_pid) do
        %Run{
          ref: make_ref(),
          adapter: @adapter,
          port: port,
          os_pid: os_pid,
          started_at: System.monotonic_time()
        }
      end

      describe "capabilities/0 — capability declaration" do
        test "declares a Capabilities struct carrying the autonomous baseline" do
          caps = @adapter.capabilities()

          assert %Capabilities{} = caps

          assert :autonomous in caps.permission_modes,
                 ":autonomous is the mandatory baseline every adapter must support"

          assert is_boolean(caps.session_resume)
          assert is_boolean(caps.streaming_output)
        end
      end

      describe "build_command/1 — invocation" do
        test "builds a spawnable {executable, argv, env} for the autonomous baseline" do
          assert {:ok, {executable, argv, env}} = @adapter.build_command(invocation())

          assert is_binary(executable) and executable != ""
          assert is_list(argv) and Enum.all?(argv, &is_binary/1)

          assert Enum.all?(env, fn
                   {key, value} -> is_binary(key) and is_binary(value)
                   _other -> false
                 end)
        end

        test "accepts every permission mode it declares in capabilities/0" do
          for mode <- @adapter.capabilities().permission_modes do
            assert {:ok, {_executable, _argv, _env}} =
                     @adapter.build_command(invocation(permission_mode: mode)),
                   "build_command/1 must accept declared permission mode #{inspect(mode)}"
          end
        end

        test "rejects a permission mode it does not declare, with no silent fallback" do
          undeclared = :conformance_undeclared_mode
          refute undeclared in @adapter.capabilities().permission_modes

          assert {:error, _reason} = @adapter.build_command(invocation(permission_mode: undeclared))
        end
      end

      describe "classify_message/2 — raw-output capture & termination detection" do
        test "maps a port data chunk to verbatim raw output" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          # Non-UTF8 bytes plus embedded structure: proves the adapter captures
          # the agent's output untouched — no parsing, no normalization, no
          # re-encoding.
          raw = <<0, 255>> <> ~s({"type":"assistant"}) <> "\n"

          assert {:output, ^raw, captured} = @adapter.classify_message({port, {:data, raw}}, run)
          assert captured.ref == run.ref
        end

        test "maps an exit status to termination, carrying the code without judging it" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          assert {:terminated, ended, 0} = @adapter.classify_message({port, {:exit_status, 0}}, run)
          assert ended.ref == run.ref

          # A non-zero code is termination too — exit status is advisory, never
          # itself a failure signal.
          assert {:terminated, _ended, 137} =
                   @adapter.classify_message({port, {:exit_status, 137}}, run)
        end

        test "ignores a message from a port that is not this run's" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          {other_port, _other_os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          assert :ignore = @adapter.classify_message({other_port, {:data, "stray"}}, run)
          assert :ignore = @adapter.classify_message({other_port, {:exit_status, 0}}, run)
        end

        test "ignores a foreign, non-port message" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          assert :ignore = @adapter.classify_message(:unrelated, run)
          assert :ignore = @adapter.classify_message({:not, :a, :port, :message}, run)
        end
      end

      describe "terminate/1 — adapter-level cancellation" do
        test "kills an in-flight run, releases its port, and is idempotent" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          assert is_integer(os_pid)
          assert :ok = @adapter.terminate(run)
          refute Port.info(port)
          assert ProcessFixture.await_dead(os_pid) == :ok

          # Idempotent — safe on a run that has already ended.
          assert :ok = @adapter.terminate(run)
        end
      end

      describe "timeout — terminate/1 as the driver's timeout-branch handler" do
        test "reaps a run abandoned when a driver-shaped receive loop hits its deadline" do
          {port, os_pid} = ProcessFixture.spawn_sleep()
          run = conformance_run(port, os_pid)

          # Harness.AgentAdapter.Driver.loop/6 enforces the idle/total deadlines
          # and, when one fires, calls the adapter's terminate/1. This mirrors
          # that branch: the stand-in emits nothing, so the `after` always wins,
          # exactly as it would for a wedged agent. The adapter-scoped contract
          # is that terminate/1 then reaps the OS process — the driver's own
          # deadline arithmetic is generic and covered by DriverTest.
          result =
            receive do
              message -> flunk("stand-in unexpectedly sent #{inspect(message)}")
            after
              150 -> @adapter.terminate(run)
            end

          assert result == :ok
          refute Port.info(port)
          assert ProcessFixture.await_dead(os_pid) == :ok
        end
      end

      describe "live end-to-end through Harness.AgentAdapter.Driver (real agent)" do
        @tag :integration
        test "drives a real run through invocation, raw capture and termination" do
          repo = GitFixture.init_repo()
          request = invocation(prompt: "Reply with exactly the word: pong", cwd: repo)

          case Driver.run(@adapter, request, total_timeout: 120_000, idle_timeout: 60_000) do
            {:ok, %Outcome{} = outcome} ->
              # The adapter's job: spawn, capture raw output, report termination
              # — not judge what the agent produced. A non-empty capture and an
              # :exited kind is the whole adapter-scoped contract.
              assert outcome.kind == :exited
              assert byte_size(outcome.output) > 0

            {:error, {:executable_not_found, executable}} ->
              flunk("""
              `#{executable}` is not on PATH — the #{inspect(@adapter)} conformance
              integration test cannot run. Install the agent's CLI, then re-run:

                  mix test --include integration
              """)
          end
        end
      end
    end
  end
end
