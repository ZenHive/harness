defmodule Harness.VerificationTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  @fixture_root Path.expand("../support/fixtures", __DIR__)

  describe "run/2 aggregation" do
    test "all checks passing yields a :pass verdict" do
      dir = worktree_dir()

      assert {:ok, %Verdict{status: :pass, results: results}} =
               Verification.run(dir, checks: [check("a", "true"), check("b", "true")])

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :pass))
      assert Enum.all?(results, &(&1.kind == :exited))
      assert Enum.all?(results, &(&1.exit_status == 0))
    end

    test "a single failing check makes the whole verdict red" do
      dir = worktree_dir()

      assert {:ok, %Verdict{status: :fail, results: [ok, bad]}} =
               Verification.run(dir, checks: [check("ok", "true"), check("bad", "false")])

      assert ok.status == :pass
      assert bad.status == :fail
    end

    test "all checks failing yields a :fail verdict" do
      dir = worktree_dir()

      assert {:ok, %Verdict{status: :fail, results: results}} =
               Verification.run(dir, checks: [check("x", "false"), check("y", "false")])

      assert Enum.all?(results, &(&1.status == :fail))
    end

    test "results preserve check order" do
      dir = worktree_dir()
      checks = [check("first", "true"), check("second", "true"), check("third", "true")]

      assert {:ok, %Verdict{results: results}} = Verification.run(dir, checks: checks)
      assert Enum.map(results, & &1.name) == ["first", "second", "third"]
    end

    test "every check runs even after an earlier one fails" do
      dir = worktree_dir()
      sentinel = Path.join(System.tmp_dir!(), "sentinel_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(sentinel) end)
      checks = [check("fails", "false"), check("touches", stub_script("touch #{sentinel}"))]

      assert {:ok, %Verdict{status: :fail, results: [_fails, touched]}} =
               Verification.run(dir, checks: checks)

      assert touched.status == :pass
      assert File.exists?(sentinel)
    end
  end

  describe "run/2 capture" do
    test "captures combined stdout and stderr" do
      dir = worktree_dir()
      stub = stub_script("echo to-stdout; echo to-stderr 1>&2")

      assert {:ok, %Verdict{results: [result]}} =
               Verification.run(dir, checks: [check("noisy", stub)])

      assert result.output =~ "to-stdout"
      assert result.output =~ "to-stderr"
    end

    test "captures a non-zero exit code" do
      dir = worktree_dir()

      assert {:ok, %Verdict{results: [result]}} =
               Verification.run(dir, checks: [check("exits-7", stub_script("exit 7"))])

      assert result.status == :fail
      assert result.kind == :exited
      assert result.exit_status == 7
    end

    test "runs each check in the worktree directory" do
      dir = worktree_dir()

      assert {:ok, %Verdict{results: [result]}} =
               Verification.run(dir, checks: [check("cwd", stub_script("touch ran-here"))])

      assert result.status == :pass
      assert File.exists?(Path.join(dir, "ran-here"))
    end

    test "injects check env with a per-worktree test database name" do
      dir = worktree_dir()

      stub =
        stub_script("""
        test "$MIX_ENV" = "test" || exit 3
        case "$HARNESS_DB_NAME" in
          harness_test_*) ;;
          *) exit 4 ;;
        esac
        printf "%s" "$HARNESS_DB_NAME" > db-name
        """)

      env = %{"MIX_ENV" => "test", "HARNESS_DB_NAME" => {:harness, :test_database}}
      env_check = %Check{name: "env", command: stub, args: [], env: env}

      assert {:ok, %Verdict{status: :pass, results: [result]}} =
               Verification.run(dir, checks: [env_check])

      assert result.status == :pass
      assert File.read!(Path.join(dir, "db-name")) =~ "harness_test_"
    end
  end

  describe "run/2 timeout" do
    test "kills an idle check that exceeds the timeout and grades it red" do
      dir = worktree_dir()
      stub = stub_script("echo started; sleep 30; echo finished")
      began = System.monotonic_time(:millisecond)

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(dir, checks: [check("hangs", stub)], timeout: 300)

      elapsed = System.monotonic_time(:millisecond) - began
      assert elapsed < 5_000
      assert result.status == :fail
      assert result.kind == :timed_out
      assert result.exit_status == nil
      assert result.output =~ "timed out after 300ms"
      refute result.output =~ "finished"
    end

    test "kills a check still streaming output, not just an idle one" do
      dir = worktree_dir()
      # Emits unbuffered output every 50ms forever (perl autoflush — a plain
      # shell loop block-buffers stdout to a pipe). A per-receive idle timeout
      # would never fire, since every chunk resets it; this is the case the
      # absolute deadline exists for. The check must still die at the deadline.
      # The 2s budget leaves comfortable room for perl's interpreter start under
      # heavy suite load (1s occasionally lost the startup race → no tick emitted).
      stub =
        stub_script(~S[exec perl -e '$| = 1; while (1) { print "tick\n"; select(undef, undef, undef, 0.05); }'])

      began = System.monotonic_time(:millisecond)

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(dir, checks: [check("streams", stub)], timeout: 2_000)

      elapsed = System.monotonic_time(:millisecond) - began
      assert elapsed < 5_000
      assert result.kind == :timed_out
      assert result.output =~ "tick"
      assert result.output =~ "timed out after 2000ms"
    end

    test "an :infinity timeout leaves the check unbounded" do
      dir = worktree_dir()

      assert {:ok, %Verdict{status: :pass, results: [result]}} =
               Verification.run(dir, checks: [check("quick", "true")], timeout: :infinity)

      assert result.kind == :exited
    end
  end

  describe "run/2 errors" do
    test "an empty check list is an error, never a vacuous pass" do
      assert {:error, :no_checks} = Verification.run(worktree_dir(), checks: [])
    end

    test "a non-existent worktree path is an error with the expanded path" do
      missing = Path.join(System.tmp_dir!(), "harness-missing-#{System.unique_integer([:positive])}")

      assert {:error, {:worktree_not_found, expanded}} =
               Verification.run(missing, checks: [check("a", "true")])

      assert expanded == Path.expand(missing)
    end

    test "an executable not on PATH fails its check but not the run" do
      dir = worktree_dir()
      checks = [check("ghost", "definitely-not-a-real-binary-xyz"), check("real", "true")]

      assert {:ok, %Verdict{status: :fail, results: [ghost, real]}} =
               Verification.run(dir, checks: checks)

      assert ghost.status == :fail
      assert ghost.kind == :not_launched
      assert ghost.exit_status == nil
      assert ghost.output =~ "definitely-not-a-real-binary-xyz"
      assert real.status == :pass
      assert real.kind == :exited
    end
  end

  describe "run/2 configuration" do
    test "falls back to the configured check stack when no :checks option is given" do
      # The only test that exercises run/2 without :checks, so its brief mutation
      # of the :harness, :verification env races no other case in the async suite.
      dir = worktree_dir()
      Application.put_env(:harness, :verification, checks: [check("from-config", "true")], timeout: 5_000)
      on_exit(fn -> Application.delete_env(:harness, :verification) end)

      assert {:ok, %Verdict{status: :pass, results: [result]}} = Verification.run(dir)
      assert result.name == "from-config"
    end
  end

  describe "run/2 with :check_stack" do
    test "runs the stack's checks and produces the same Verdict shape" do
      dir = worktree_dir()

      stack = %CheckStack{
        name: :tiny,
        checks: [check("a", "true"), check("b", "true")]
      }

      assert {:ok, %Verdict{status: :pass, results: [a, b]}} =
               Verification.run(dir, check_stack: stack)

      assert a.name == "a"
      assert b.name == "b"
      assert Enum.all?([a, b], &match?(%Result{kind: :exited, status: :pass}, &1))
    end

    test "applies the stack's timeout_per_check when no explicit :timeout is given" do
      dir = worktree_dir()
      stub = stub_script("sleep 30; echo done")

      stack = %CheckStack{
        name: :tight,
        checks: [check("hangs", stub)],
        timeout_per_check: 200
      }

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(dir, check_stack: stack)

      assert result.kind == :timed_out
      assert result.output =~ "timed out after 200ms"
    end

    test "an explicit :timeout wins over the stack's timeout_per_check" do
      dir = worktree_dir()
      stub = stub_script("sleep 30; echo done")

      stack = %CheckStack{
        name: :loose,
        checks: [check("hangs", stub)],
        # If this 60_000 leaked through, the test would block for 30 s.
        timeout_per_check: 60_000
      }

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(dir, check_stack: stack, timeout: 200)

      assert result.kind == :timed_out
      assert result.output =~ "timed out after 200ms"
    end

    test "wins over a raw :checks option" do
      dir = worktree_dir()

      stack = %CheckStack{name: :winner, checks: [check("from-stack", "true")]}

      assert {:ok, %Verdict{results: [result]}} =
               Verification.run(dir, check_stack: stack, checks: [check("ignored", "false")])

      assert result.name == "from-stack"
      assert result.status == :pass
    end
  end

  describe "run/2 setup bootstrap" do
    test "a setup failure is an environment error, not a red verdict" do
      dir = worktree_dir()

      stack = %CheckStack{
        name: :broken,
        setup: [check("bootstrap", "false")],
        checks: [check("never-runs", stub_script("touch should-not-exist"))]
      }

      assert {:error, {:setup_failed, %{stack: :broken, workdir: ^dir, result: result}}} =
               Verification.run(dir, check_stack: stack)

      assert result.name == "bootstrap"
      assert result.status == :fail
      refute File.exists?(Path.join(dir, "should-not-exist"))
    end

    test "bootstraps deps in a fresh worktree and grades green when the code is green" do
      project = copy_elixir_fixture!()
      refute File.exists?(Path.join(project, "deps"))

      stack = %CheckStack{
        name: :elixir,
        setup: [check("deps", "mix", ["deps.get"])],
        checks: [
          check("compile", "mix", ["compile"]),
          check("test", "mix", ["test"])
        ]
      }

      assert {:ok, %Verdict{status: :pass, results: results}} =
               Verification.run(project, check_stack: stack)

      assert File.dir?(Path.join(project, "deps"))
      assert Enum.map(results, & &1.name) == ["compile", "test"]
      assert Enum.all?(results, &(&1.status == :pass))
    end

    test "without setup, a deps-dependent project fails compile in a fresh worktree" do
      project = copy_elixir_fixture!()
      refute File.exists?(Path.join(project, "deps"))

      stack = %CheckStack{
        name: :elixir,
        checks: [check("compile", "mix", ["compile"])]
      }

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(project, check_stack: stack)

      assert result.name == "compile"
      assert result.status == :fail
    end
  end

  describe "run/2 with :check_stacks (multi-stack / workdir)" do
    test "runs a stack's checks in its workdir, relative to the worktree root" do
      repo = worktree_dir()
      File.mkdir_p!(Path.join(repo, "sub"))
      File.write!(Path.join([repo, "sub", "marker"]), "")

      # `test -f marker` passes only if the check ran with repo/sub as its cwd.
      stack = %CheckStack{name: :sub, workdir: "sub", checks: [check("in-sub", "test", ["-f", "marker"])]}

      assert {:ok, %Verdict{status: :pass, results: [result]}} =
               Verification.run(repo, check_stacks: [stack])

      assert result.name == "in-sub"
      assert result.status == :pass
    end

    test "a workdir-scoped check fails when it would have passed only at the repo root" do
      repo = worktree_dir()
      File.mkdir_p!(Path.join(repo, "sub"))
      File.write!(Path.join(repo, "marker"), "")

      # marker is at the root, not in sub/, so the workdir-scoped check reds.
      stack = %CheckStack{name: :sub, workdir: "sub", checks: [check("in-sub", "test", ["-f", "marker"])]}

      assert {:ok, %Verdict{status: :fail, results: [result]}} =
               Verification.run(repo, check_stacks: [stack])

      assert result.status == :fail
    end

    test "errors with {:workdir_not_found, dir} when a stack's workdir is missing" do
      repo = worktree_dir()
      stack = %CheckStack{name: :gone, workdir: "nope", checks: [check("x", "true")]}

      assert {:error, {:workdir_not_found, dir}} =
               Verification.run(repo, check_stacks: [stack])

      assert dir == Path.join(repo, "nope")
    end

    test "flattens results from all stacks and reds if any stack reds" do
      repo = worktree_dir()
      File.mkdir_p!(Path.join(repo, "a"))
      File.mkdir_p!(Path.join(repo, "b"))

      stacks = [
        %CheckStack{name: :a, workdir: "a", checks: [check("a-ok", "true")]},
        %CheckStack{name: :b, workdir: "b", checks: [check("b-bad", "false")]}
      ]

      assert {:ok, %Verdict{status: :fail, results: [a, b]}} =
               Verification.run(repo, check_stacks: stacks)

      assert a.name == "a-ok"
      assert a.status == :pass
      assert b.name == "b-bad"
      assert b.status == :fail
    end

    test "is green when every stack is green" do
      repo = worktree_dir()
      File.mkdir_p!(Path.join(repo, "a"))

      stacks = [
        %CheckStack{name: :root, workdir: "", checks: [check("root-ok", "true")]},
        %CheckStack{name: :a, workdir: "a", checks: [check("a-ok", "true")]}
      ]

      assert {:ok, %Verdict{status: :pass, results: [_, _]}} =
               Verification.run(repo, check_stacks: stacks)
    end
  end

  describe "elixir_preset/0" do
    test "returns the five-tool mix quality stack" do
      preset = Verification.elixir_preset()

      assert length(preset) == 5
      assert Enum.all?(preset, &match?(%Check{command: "mix"}, &1))
      assert Enum.map(preset, & &1.name) == ~w(test dialyzer credo doctor sobelow)
    end

    test "the sobelow check carries the exit-gating and inline-skip flags" do
      sobelow = Enum.find(Verification.elixir_preset(), &(&1.name == "sobelow"))
      # `--exit` makes sobelow's exit status the pass/fail signal; `--skip` makes
      # it honor the repo's `# sobelow_skip` annotations — without `--skip` the
      # check reds every run on already-triaged low-confidence findings.
      assert "--exit" in sobelow.args
      assert "--skip" in sobelow.args
    end
  end

  describe "Verdict.passed?/1" do
    test "is true for a :pass verdict and false for a :fail verdict" do
      assert Verdict.passed?(%Verdict{status: :pass, results: []})
      refute Verdict.passed?(%Verdict{status: :fail, results: []})
    end
  end

  describe "struct key enforcement" do
    test "Check, Result and Verdict enforce their keys" do
      assert_raise ArgumentError, fn -> struct!(Check, name: "x") end
      assert_raise ArgumentError, fn -> struct!(Result, name: "x") end
      assert_raise ArgumentError, fn -> struct!(Verdict, status: :pass) end
    end
  end

  # A throwaway directory that exists — the worktree a verification run grades.
  defp worktree_dir do
    dir = GitFixture.tmp_base()
    File.mkdir_p!(dir)
    dir
  end

  defp check(name, command, args \\ []) do
    %Check{name: name, command: command, args: args}
  end

  # Writes an executable `/bin/sh` stub standing in for a check command, cleaned
  # up after the test. `body` is the shell line(s) the stub runs.
  defp stub_script(body) do
    path = Path.join(System.tmp_dir!(), "check_stub_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp copy_elixir_fixture! do
    source = Path.join(@fixture_root, "elixir_project")
    dest = Path.join(System.tmp_dir!(), "harness_elixir_#{System.unique_integer([:positive])}")
    File.cp_r!(source, dest)
    on_exit(fn -> File.rm_rf!(dest) end)
    dest
  end
end
