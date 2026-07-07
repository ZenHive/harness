defmodule Harness.AgentAdapter.CodexTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Invocation

  setup do
    cwd = Path.join(System.tmp_dir!(), "harness-codex-#{System.unique_integer()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp invocation(cwd, attrs \\ []) do
    struct!(%Invocation{prompt: "do the task", cwd: cwd, log_tag: "7"}, attrs)
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
    test "builds a headless --json run for the autonomous baseline", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd))

      assert argv == [
               "exec",
               "--cd",
               cwd,
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "do the task"
             ]

      assert File.exists?(Path.join(cwd, "AGENTS.md"))
    end

    test "pins the agent's working root to the invocation cwd via --cd at the exec level", %{cwd: cwd} do
      # Regression for Task 41: without --cd, Codex's heuristic workspace
      # resolution can walk a linked worktree's .git pointer back to the main
      # checkout. The flag must sit at the exec level (before any subcommand)
      # because clap rejects `exec resume --cd …` as an unexpected argument.
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd))

      cd_index = Enum.find_index(argv, &(&1 == "--cd"))
      assert cd_index, "argv must carry --cd"
      assert Enum.at(argv, cd_index + 1) == cwd
      assert Enum.at(argv, 0) == "exec", "--cd must follow the exec subcommand"
      assert cd_index < Enum.find_index(argv, &(&1 == "--json")), "--cd precedes exec-level flags"
    end

    test "passes the model through as --model", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} =
               Codex.build_command(invocation(cwd, model: "gpt-5-codex"))

      assert argv == [
               "exec",
               "--cd",
               cwd,
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--model",
               "gpt-5-codex",
               "do the task"
             ]
    end

    test "swaps in the resume subcommand and appends --last for a :resume session", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd, session: :resume))

      assert argv == [
               "exec",
               "--cd",
               cwd,
               "resume",
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--last",
               "do the task"
             ]
    end

    test "keeps --cd before resume on a session-resume run (clap rejects exec-level options after the subcommand)", %{
      cwd: cwd
    } do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd, session: :resume))

      cd_index = Enum.find_index(argv, &(&1 == "--cd"))
      resume_index = Enum.find_index(argv, &(&1 == "resume"))
      assert cd_index < resume_index, "--cd must precede the resume subcommand"
    end

    test "omits the resume subcommand and --last for a fresh run", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} = Codex.build_command(invocation(cwd))
      refute "resume" in argv
      refute "--last" in argv
    end

    test "orders model then --last, with the prompt last on a resume", %{cwd: cwd} do
      assert {:ok, {"codex", argv, []}} =
               Codex.build_command(invocation(cwd, model: "gpt-5-codex", session: :resume))

      assert argv == [
               "exec",
               "--cd",
               cwd,
               "resume",
               "--json",
               "--dangerously-bypass-approvals-and-sandbox",
               "--model",
               "gpt-5-codex",
               "--last",
               "do the task"
             ]
    end

    test "rejects a permission mode outside its capabilities", %{cwd: cwd} do
      assert {:error, {:unsupported_permission_mode, :plan}} =
               Codex.build_command(invocation(cwd, permission_mode: :plan))
    end

    test "rejects a session value that is not the :resume sentinel", %{cwd: cwd} do
      assert {:error, {:unsupported_session_token, "abc-123"}} =
               Codex.build_command(invocation(cwd, session: "abc-123"))
    end

    test "two concurrent invocations carry distinct --cd paths (parallel-batch regression for Task 41)", %{cwd: cwd} do
      # In a parallel `Harness.Batch.run`, every `Harness.Run` builds its own
      # `Invocation` against its own worktree path. The adapter must pull `--cd`
      # from *this* invocation only — a stale capture (module attribute, ETS
      # cache, process dictionary) would collapse two parallel runs onto one
      # cwd. Build two adapters in two Tasks and assert the argvs disagree on
      # the --cd argument.
      sibling = Path.join(System.tmp_dir!(), "harness-codex-sibling-#{System.unique_integer()}")
      File.mkdir_p!(sibling)
      on_exit(fn -> File.rm_rf!(sibling) end)

      [{:ok, argv_a}, {:ok, argv_b}] =
        [cwd, sibling]
        |> Enum.map(fn dir ->
          Task.async(fn ->
            {:ok, {"codex", argv, _env}} = Codex.build_command(invocation(dir))
            {:ok, argv}
          end)
        end)
        |> Task.await_many(5_000)

      assert Enum.at(argv_a, Enum.find_index(argv_a, &(&1 == "--cd")) + 1) == cwd
      assert Enum.at(argv_b, Enum.find_index(argv_b, &(&1 == "--cd")) + 1) == sibling
    end
  end
end
