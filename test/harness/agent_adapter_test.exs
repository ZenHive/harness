defmodule Harness.AgentAdapterTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentAdapter.Run
  alias Harness.FakeAdapter
  alias Harness.ProcessFixture

  # Minimal adapter implementing the three required callbacks
  # (capabilities/0, rule_channel/0, build_command/1). Proves defaults for
  # classify_message/2 and terminate/1 satisfy the contract; exercises
  # supports?/2 false branches and the build_command error path of invoke/2.
  defmodule MinimalAdapter do
    @moduledoc false
    use AgentAdapter

    @impl AgentAdapter
    def capabilities, do: %Capabilities{streaming_output: false}

    @impl AgentAdapter
    def rule_channel, do: :none

    @impl AgentAdapter
    def build_command(_invocation), do: {:error, :not_implemented}
  end

  defp invocation(adapter_opts \\ []) do
    %Invocation{prompt: "do the task", cwd: "/tmp", task_id: "3", adapter_opts: adapter_opts}
  end

  # Drive a run the way the lifecycle process will: feed every received message
  # through classify_message/2 until the run terminates.
  defp drive(adapter, run, acc \\ []) do
    receive do
      message ->
        case adapter.classify_message(message, run) do
          {:output, data, next_run} -> drive(adapter, next_run, [acc, data])
          {:terminated, _run, status} -> {IO.iodata_to_binary(acc), status}
          {:error, reason, _run} -> flunk("unexpected classify_message error: #{inspect(reason)}")
          :ignore -> drive(adapter, run, acc)
        end
    after
      5_000 -> flunk("run did not terminate within 5s")
    end
  end

  describe "Capabilities" do
    test "defaults to the conservative baseline" do
      assert %Capabilities{
               session_resume: false,
               permission_modes: [:autonomous],
               streaming_output: true,
               worktree_isolation: true,
               cost_tier: :metered,
               auth_env_scrub: [],
               model_families: []
             } = %Capabilities{}
    end
  end

  describe "scrub_auth_env/2 (subscription billing)" do
    test "forces each declared key to {key, false}, dropping any caller-set value" do
      # Claude declares ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN so the spawned
      # `claude -p` uses the subscription login, never a stray API key.
      env = [{"PATH", "/usr/bin"}, {"ANTHROPIC_API_KEY", "sk-leftover"}]
      scrubbed = AgentAdapter.scrub_auth_env(Claude, env)

      assert {"PATH", "/usr/bin"} in scrubbed
      assert {"ANTHROPIC_API_KEY", false} in scrubbed
      assert {"ANTHROPIC_AUTH_TOKEN", false} in scrubbed
      # The caller's real value is gone — only the unset pair survives.
      refute {"ANTHROPIC_API_KEY", "sk-leftover"} in scrubbed
    end

    test "is a no-op for an adapter that declares no scrub" do
      env = [{"ANTHROPIC_API_KEY", "sk-keepme"}]
      assert AgentAdapter.scrub_auth_env(FakeAdapter, env) == env
    end

    test "declared adapter scrubs force API-key env vars unset" do
      cases = [
        {Claude, ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]},
        {Codex, ["OPENAI_API_KEY"]},
        {Cursor, ["CURSOR_API_KEY"]},
        {Grok, ["XAI_API_KEY"]}
      ]

      for {adapter, keys} <- cases, key <- keys do
        assert key in adapter.capabilities().auth_env_scrub

        env = [{"PATH", "/usr/bin"}, {key, "stray-key"}]
        scrubbed = AgentAdapter.scrub_auth_env(adapter, env)

        assert {"PATH", "/usr/bin"} in scrubbed
        assert {key, false} in scrubbed
        refute {key, "stray-key"} in scrubbed
      end
    end

    test "Pi and Antigravity honestly declare no verified diverting env scrub" do
      env = [{"GEMINI_API_KEY", "gemini-key"}, {"GOOGLE_API_KEY", "google-key"}]

      assert Pi.capabilities().auth_env_scrub == []
      assert Antigravity.capabilities().auth_env_scrub == []
      assert AgentAdapter.scrub_auth_env(Pi, env) == env
      assert AgentAdapter.scrub_auth_env(Antigravity, env) == env
    end

    test "Claude and Codex declare their provider key scrubs" do
      assert "ANTHROPIC_API_KEY" in Claude.capabilities().auth_env_scrub
      assert "OPENAI_API_KEY" in Codex.capabilities().auth_env_scrub
    end
  end

  describe "Invocation" do
    test "enforces prompt, cwd and task_id" do
      assert_raise ArgumentError, fn -> struct!(Invocation, prompt: "p", cwd: "/tmp") end
    end

    test "defaults the how-to-run fields" do
      invocation = %Invocation{prompt: "p", cwd: "/tmp", task_id: "3"}
      assert invocation.session == nil
      assert invocation.permission_mode == :autonomous
      assert invocation.model == nil
      assert invocation.languages == [:elixir]
      assert invocation.adapter_opts == []
      assert invocation.env == %{}
    end
  end

  describe "Run" do
    test "enforces the harness-owned fields" do
      assert_raise ArgumentError, fn -> struct!(Run, ref: make_ref()) end
    end
  end

  describe "behaviour" do
    test "declares the four adapter callbacks" do
      callbacks = AgentAdapter.behaviour_info(:callbacks)

      for callback <- [
            {:capabilities, 0},
            {:build_command, 1},
            {:classify_message, 2},
            {:terminate, 1}
          ] do
        assert callback in callbacks
      end
    end

    test "a minimal adapter (only capabilities/0 + build_command/1) gets classify/terminate from defaults" do
      assert function_exported?(MinimalAdapter, :classify_message, 2)
      assert function_exported?(MinimalAdapter, :terminate, 1)
      # defaults behave correctly for non-matching messages
      dummy_run = %Run{ref: make_ref(), adapter: MinimalAdapter, port: nil, os_pid: nil, started_at: 0}
      assert :ignore = MinimalAdapter.classify_message(:unrelated, dummy_run)
    end
  end

  describe "supports?/2" do
    test "reflects the adapter's capability declaration" do
      assert AgentAdapter.supports?(FakeAdapter, :session_resume)
      assert AgentAdapter.supports?(FakeAdapter, :streaming_output)
      assert AgentAdapter.supports?(FakeAdapter, {:permission_mode, :autonomous})
      assert AgentAdapter.supports?(FakeAdapter, {:permission_mode, :plan})

      refute AgentAdapter.supports?(FakeAdapter, {:permission_mode, :unknown})
      refute AgentAdapter.supports?(MinimalAdapter, :session_resume)
      refute AgentAdapter.supports?(MinimalAdapter, :streaming_output)
      assert AgentAdapter.supports?(MinimalAdapter, {:permission_mode, :autonomous})
    end

    test "queries {:cost_tier, tier} against the adapter's declared tier" do
      # FakeAdapter and MinimalAdapter both inherit the :metered default.
      assert AgentAdapter.supports?(FakeAdapter, {:cost_tier, :metered})
      refute AgentAdapter.supports?(FakeAdapter, {:cost_tier, :free})
      assert AgentAdapter.supports?(MinimalAdapter, {:cost_tier, :metered})
      refute AgentAdapter.supports?(MinimalAdapter, {:cost_tier, :free})
    end
  end

  describe "model_supported?/2" do
    test "rejects an unpinned model for a model-capable adapter" do
      refute AgentAdapter.model_supported?(Codex, nil)
      refute AgentAdapter.model_supported?(Cursor, nil)
    end

    test "accepts an unpinned model only for a model-incapable adapter" do
      assert AgentAdapter.model_supported?(FakeAdapter, nil)
    end

    test "rejects an unpinned model for antigravity now that it is model-capable" do
      refute AgentAdapter.model_supported?(Antigravity, nil)
    end

    test "accepts compatible model families" do
      assert AgentAdapter.model_supported?(Cursor, "claude-opus-4-8-thinking-high")
      assert AgentAdapter.model_supported?(Codex, "gpt-5-codex")
      assert AgentAdapter.model_supported?(Antigravity, "gemini-3.5-flash")
      assert AgentAdapter.model_supported?(Antigravity, "gpt-oss-120b")
    end

    test "rejects an incompatible cursor-only opus pin on the codex adapter" do
      refute AgentAdapter.model_supported?(Codex, "claude-opus-4-8-thinking-high")
    end

    test "rejects an unknown antigravity pin at the family layer (catalog guard is in build_command)" do
      refute AgentAdapter.model_supported?(Antigravity, "custom-model")
    end
  end

  describe "requires_model?/1" do
    test "true for model-capable adapters, false for model-incapable ones" do
      assert AgentAdapter.requires_model?(Codex)
      assert AgentAdapter.requires_model?(Cursor)
      assert AgentAdapter.requires_model?(Antigravity)
      refute AgentAdapter.requires_model?(FakeAdapter)
    end
  end

  describe "build_command/1" do
    test "is pure and returns the spawn recipe without spawning" do
      assert {:ok, {"/bin/echo", ["harness-test"], []}} = FakeAdapter.build_command(invocation())
    end
  end

  describe "invoke/2" do
    test "rejects incompatible model pins before command build or spawn" do
      model = "claude-opus-4-8-thinking-high"

      assert {:error, {:invalid_model_for_adapter, Codex, ^model}} =
               AgentAdapter.invoke(Codex, %{invocation() | model: model})
    end

    test "spawns the agent and captures raw output through to termination" do
      assert {:ok, %Run{} = run} = AgentAdapter.invoke(FakeAdapter, invocation())
      assert run.adapter == FakeAdapter
      assert is_reference(run.ref)
      assert is_port(run.port)
      assert is_integer(run.started_at)
      assert run.adapter_state == nil

      assert {"harness-test\n", 0} = drive(FakeAdapter, run)
    end

    test "returns the adapter's build_command error without spawning" do
      assert {:error, :not_implemented} = AgentAdapter.invoke(MinimalAdapter, invocation())
    end

    test "rejects an unpinned model for a model-capable adapter before command build or spawn" do
      assert {:error, {:model_required, Codex}} = AgentAdapter.invoke(Codex, invocation())
    end

    test "accepts an unpinned model for a model-incapable adapter" do
      assert {:ok, %Run{}} = AgentAdapter.invoke(FakeAdapter, invocation())
    end

    test "returns an error when the executable is not on PATH" do
      assert {:error, {:executable_not_found, "definitely-not-a-real-binary-xyz"}} =
               AgentAdapter.invoke(FakeAdapter, invocation(command: :missing))
    end

    test "fails loudly before spawn when the invocation cwd has been cleaned up" do
      cwd = Path.join(System.tmp_dir!(), "harness-missing-cwd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      File.rm_rf!(cwd)

      assert {:error, {:cwd_missing, ^cwd}} = AgentAdapter.invoke(FakeAdapter, %{invocation() | cwd: cwd})
    end
  end

  describe "invoke/2 — Port-spawned agent stdin (Task 23)" do
    test "a stdin-reading agent gets an immediate EOF, never a stall" do
      # An OTP port leaves the child's stdin an open, empty pipe; an agent that
      # reads stdin (here `cat`) blocks on it forever. The harness spawn wrapper
      # redirects stdin from /dev/null, so `cat` hits EOF at once and the script
      # runs on to its marker — termination itself is the proof.
      assert {:ok, %Run{} = run} = AgentAdapter.invoke(FakeAdapter, invocation(command: :stdin_eof))
      assert {"stdin-eof-ok\n", 0} = drive(FakeAdapter, run)
    end

    test "argv reaches the agent verbatim — no shell word-splitting or expansion" do
      hazard = ~S[a b; echo INJECTED && $(echo X) `echo Y` * "q" 'r' ~]

      assert {:ok, %Run{} = run} =
               AgentAdapter.invoke(FakeAdapter, invocation(command: {:echo, hazard}))

      assert {output, 0} = drive(FakeAdapter, run)
      assert output == hazard <> "\n"
    end
  end

  describe "terminate/1" do
    test "kills an in-flight run and releases its port" do
      assert {:ok, run} = AgentAdapter.invoke(FakeAdapter, invocation(command: :sleep))
      assert is_integer(run.os_pid)

      assert :ok = FakeAdapter.terminate(run)
      refute Port.info(run.port)
      assert ProcessFixture.await_dead(run.os_pid) == :ok

      # Idempotent — safe to call on a run that has already ended.
      assert :ok = FakeAdapter.terminate(run)
    end
  end
end
