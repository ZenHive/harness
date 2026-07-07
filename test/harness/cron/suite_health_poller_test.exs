defmodule Harness.Cron.SuiteHealthPollerTest do
  use ExUnit.Case, async: false

  alias Harness.Cron.SuiteHealthPoller
  alias Harness.GitFixture
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth
  alias Harness.SuiteHealthStore.Memory, as: Store
  alias Oban.Plugins.Cron

  setup do
    prev = Application.get_env(:harness, :suite_health_store)
    Application.put_env(:harness, :suite_health_store, {Store, scope: :suite_health_cron_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :suite_health_store, prev)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "cron plugin registers with a daily schedule" do
    crontab =
      HarnessOban.oban_opts()
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Cron, opts} -> Keyword.get(opts, :crontab, [])
        _other -> nil
      end)

    entry = SuiteHealthPoller.cron_entry()
    assert entry in crontab
    assert {"0 0 * * *", SuiteHealthPoller, [queue: :cron, max_attempts: 1]} = entry
  end

  test "perform/1 checks registered projects" do
    %{repo: repo} = GitFixture.init_with_origin(name: "suite-health-cron")
    File.write!(Path.join(repo, "mix.exs"), "Mix.install([])\n")
    GitFixture.git!(repo, ["add", "mix.exs"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "mix"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])

    project =
      ProjectFixture.from_repo(repo,
        name: "suite-health-cron",
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

    assert :ok = SuiteHealthPoller.perform(%Oban.Job{})
    assert {:ok, result} = SuiteHealth.fetch_result("suite-health-cron")
    assert result.passed == true
  end
end
