defmodule Harness.SuiteHealth.BootstrapTest do
  @moduledoc """
  Guards the two ways a suite-health check used to fail without saying so:
  a `deps.get` that never ran, and a failure reason too long to store.
  """

  use ExUnit.Case, async: true

  alias Harness.ProjectFixture
  alias Harness.SuiteHealth.Bootstrap
  alias Harness.SuiteHealth.Result

  setup do
    path = Path.join(System.tmp_dir!(), "suite-health-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), "Mix.install([])\n")
    on_exit(fn -> File.rm_rf!(path) end)

    {:ok, path: path, project: ProjectFixture.from_repo(path, name: "bootstrap-test", languages: [:elixir])}
  end

  defp recording_runner(pid) do
    fn cmd, args, _cwd, _env ->
      send(pid, {:invoked, cmd, args})
      {"", 0}
    end
  end

  describe "ensure_deps" do
    test "fetches deps even when a warmed deps/ is already present", %{path: path, project: project} do
      # Harness.Worktree seeds every worktree from the parent checkout via
      # @default_warm_paths ["deps", "_build", "priv/plts"], so deps/ exists
      # before bootstrap looks. The old File.dir?/1 guard therefore skipped the
      # fetch unconditionally and a drifted mix.lock only surfaced later as
      # "lock mismatch ... Can't continue due to errors on dependencies".
      File.mkdir_p!(Path.join(path, "deps"))

      assert :ok = Bootstrap.prepare(project, path, runner: recording_runner(self()))
      assert_received {:invoked, "mix", ["deps.get" | _]}
    end

    test "fetches deps when deps/ is absent", %{path: path, project: project} do
      assert :ok = Bootstrap.prepare(project, path, runner: recording_runner(self()))
      assert_received {:invoked, "mix", ["deps.get" | _]}
    end

    test "surfaces a failed fetch instead of continuing", %{path: path, project: project} do
      File.mkdir_p!(Path.join(path, "deps"))
      runner = fn "mix", ["deps.get" | _], _cwd, _env -> {"boom", 1} end

      assert {:error, {:deps_get_failed, 1, "boom"}} = Bootstrap.prepare(project, path, runner: runner)
    end
  end

  describe "skip_reason bound" do
    test "an over-long reason is truncated to the column width" do
      # inspect/1 of {:ecto_bootstrap_failed, exit, output} carries the whole
      # mix output. skip_reason is a varchar(255); an unbounded value was
      # rejected with 22001 and the witness silently never written, leaving the
      # dashboard on a stale upserted row.
      reason = String.duplicate("x", 5_000)

      result = Result.skipped("proj", reason)

      assert String.length(result.skip_reason) <= Result.skip_reason_limit()
      assert String.ends_with?(result.skip_reason, "…")
      assert String.starts_with?(result.skip_reason, "xxxx")
    end

    test "a short reason is stored verbatim" do
      assert Result.skipped("proj", "no suite commands").skip_reason == "no suite commands"
    end
  end
end
