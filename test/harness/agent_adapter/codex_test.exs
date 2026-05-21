defmodule Harness.AgentAdapter.CodexTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Invocation

  # Codex-specific adapter behaviour. The agent-agnostic contract — invocation,
  # raw-output capture, termination detection, timeout, adapter-level
  # cancellation, and the live end-to-end run — is exercised by the shared
  # conformance suite (`Harness.AgentAdapter.CodexConformanceTest`). What stays
  # here is what only Codex does: argv composition, the
  # `--dangerously-bypass-approvals-and-sandbox` autonomous mapping, and the
  # `exec`/`exec resume` subcommand swap behind the `:resume` session sentinel.

  # `codex exec` for a fresh autonomous run, before model/resume/prompt.
  @baseline_argv ["exec", "--json", "--dangerously-bypass-approvals-and-sandbox"]

  # `codex exec resume` for an autonomous resume, before model/--last/prompt.
  @resume_argv ["exec", "resume", "--json", "--dangerously-bypass-approvals-and-sandbox"]

  defp invocation(attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: "/tmp", task_id: "7"}, attrs)
  end

  describe "capabilities/0" do
    test "declares resume + streaming output, autonomous-only permission mode" do
      assert %Capabilities{
               session_resume: true,
               streaming_output: true,
               permission_modes: [:autonomous]
             } = Codex.capabilities()
    end
  end

  describe "build_command/1" do
    test "builds a headless --json run for the autonomous baseline" do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation())
      assert argv == @baseline_argv ++ ["do the task"]
    end

    test "passes the model through as --model" do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(model: "gpt-5-codex"))
      assert argv == @baseline_argv ++ ["--model", "gpt-5-codex", "do the task"]
    end

    test "swaps in the resume subcommand and appends --last for a :resume session" do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(session: :resume))
      assert argv == @resume_argv ++ ["--last", "do the task"]
    end

    test "omits the resume subcommand and --last for a fresh run" do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation())
      refute "resume" in argv
      refute "--last" in argv
    end

    test "orders model then --last, with the prompt last on a resume" do
      assert {:ok, {"codex", argv, []}} =
               Codex.build_command(invocation(model: "gpt-5-codex", session: :resume))

      assert argv == @resume_argv ++ ["--model", "gpt-5-codex", "--last", "do the task"]
    end

    test "rejects a permission mode outside its capabilities" do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Codex.build_command(invocation(permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel" do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Codex.build_command(invocation(session: "abc-123"))
    end
  end
end
