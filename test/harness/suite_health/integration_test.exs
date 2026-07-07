defmodule Harness.SuiteHealth.IntegrationTest do
  @moduledoc """
  Runs the suite-health check against a real git fixture and persists a witness.
  """

  use Harness.DataCase, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Harness.SuiteHealthStore.Postgres, as: Store

  @moduletag :integration

  setup do
    prev = Application.get_env(:harness, :suite_health_store)
    Application.put_env(:harness, :suite_health_store, {Store, repo: Harness.Repo})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :suite_health_store, prev)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "records a witness fact in Postgres for a project checkout" do
    %{repo: repo} = GitFixture.init_with_origin(name: "suite-health-integration")
    File.write!(Path.join(repo, "mix.exs"), "Mix.install([])\n")
    GitFixture.git!(repo, ["add", "mix.exs"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "mix"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])

    project =
      ProjectFixture.from_repo(repo,
        name: "suite-health-integration",
        target_branch: "main",
        languages: [:elixir]
      )

    :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :suite_health_runner, fn
      "mix", ["deps.get", "--quiet"], _cwd, _env ->
        {"", 0}

      "mix", ["test.json", "--quiet", "--all", "--include", "integration"], _cwd, _env ->
        {~s({"summary":{"failed":0,"result":"passed"},"tests":[]}), 0}

      _cmd, _args, _cwd, _env ->
        {"", 0}
    end)

    on_exit(fn -> Application.delete_env(:harness, :suite_health_runner) end)

    assert :ok = SuiteHealth.check_project(project)
    assert {:ok, result} = SuiteHealth.fetch_result("suite-health-integration")
    assert result.passed == true
    assert %DateTime{} = result.checked_at
  end
end
