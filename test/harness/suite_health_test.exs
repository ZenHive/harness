defmodule Harness.SuiteHealthTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Harness.SuiteHealthStore.Memory, as: Store

  setup do
    prev = Application.get_env(:harness, :suite_health_store)
    prev_runner = Application.get_env(:harness, :suite_health_runner)
    Application.put_env(:harness, :suite_health_store, {Store, scope: :suite_health_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :suite_health_store, prev)
      restore_runner(prev_runner)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "records a passing witness from a cold origin checkout" do
    %{repo: repo} = GitFixture.init_with_origin(name: "suite-health-pass")
    write_mix_project(repo)

    project =
      ProjectFixture.from_repo(repo,
        name: "suite-health-pass",
        target_branch: "main",
        languages: [:elixir]
      )

    :ok = ProjectRegistry.register(project)

    runner = fn
      "mix", ["deps.get", "--quiet"], _cwd, _env ->
        {"", 0}

      "mix", ["test.json", "--quiet", "--all", "--include", "integration"], _cwd, _env ->
        {~s({"summary":{"failed":0,"result":"passed"},"tests":[]}), 0}

      _cmd, _args, _cwd, _env ->
        flunk("unexpected runner invocation")
    end

    assert :ok = SuiteHealth.check_project(project, runner: runner)
    assert {:ok, result} = SuiteHealth.fetch_result("suite-health-pass")
    assert result.passed == true
    assert result.exit_code == 0
    assert result.failing_tests == []
    assert is_binary(result.base_sha)
    assert result.command =~ "mix test.json"
  end

  test "records failing tests raw on a red suite" do
    %{repo: repo} = GitFixture.init_with_origin(name: "suite-health-fail")
    write_mix_project(repo)

    project =
      ProjectFixture.from_repo(repo,
        name: "suite-health-fail",
        target_branch: "main",
        languages: [:elixir]
      )

    :ok = ProjectRegistry.register(project)

    output = """
    {"summary":{"failed":1,"result":"failed"},"tests":[{"state":"failed","name":"demo red","file":"test/demo_test.exs","line":3}]}
    """

    runner = fn
      "mix", ["deps.get", "--quiet"], _cwd, _env -> {"", 0}
      "mix", ["test.json", "--quiet", "--all", "--include", "integration"], _cwd, _env -> {output, 2}
      _cmd, _args, _cwd, _env -> flunk("unexpected runner")
    end

    assert :ok = SuiteHealth.check_project(project, runner: runner)
    assert {:ok, result} = SuiteHealth.fetch_result("suite-health-fail")
    assert result.passed == false
    assert result.exit_code == 2
    assert [%{name: "demo red", file: "test/demo_test.exs", line: 3}] = result.failing_tests
  end

  test "records a skipped witness when target_branch is missing" do
    repo = GitFixture.init_repo(name: "suite-health-skip")
    project = ProjectFixture.from_repo(repo, name: "suite-health-skip", languages: [:elixir])
    :ok = ProjectRegistry.register(project)

    assert :ok = SuiteHealth.check_project(project, runner: fn _, _, _, _ -> flunk("runner") end)
    assert {:ok, result} = SuiteHealth.fetch_result("suite-health-skip")
    assert result.passed == nil
    assert result.skip_reason =~ "no_target_branch"
  end

  @spec write_mix_project(String.t()) :: :ok
  defp write_mix_project(repo) do
    File.write!(Path.join(repo, "mix.exs"), """
    Mix.install([])
    """)

    GitFixture.git!(repo, ["add", "mix.exs"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "add mix project"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    :ok
  end

  @spec restore_runner(term()) :: :ok
  defp restore_runner(nil), do: Application.delete_env(:harness, :suite_health_runner)
  defp restore_runner(runner), do: Application.put_env(:harness, :suite_health_runner, runner)
end
