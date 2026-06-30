defmodule Harness.Cron.DepFreshnessPollerTest do
  use ExUnit.Case, async: false

  alias Harness.Cron.DepFreshnessPoller
  alias Harness.Cron.Settings
  alias Harness.DepFreshness
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Oban.Plugins.Cron

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    prev_runner = Application.get_env(:harness, :dep_freshness_runner)
    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :dep_freshness_cron_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    tmp_dir = Path.join(System.tmp_dir!(), "harness-freshness-cron-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Application.put_env(:harness, :dep_freshness_store, prev)
      restore_runner(prev_runner)
      File.rm_rf!(tmp_dir)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "cron plugin registers alongside the roadmap poller" do
    crontab =
      HarnessOban.oban_opts()
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Cron, opts} -> Keyword.get(opts, :crontab, [])
        _other -> nil
      end)

    entry = DepFreshnessPoller.cron_entry()

    assert entry in crontab
    assert {Cron, crontab: [^entry]} = DepFreshnessPoller.cron_plugin()
  end

  test "perform/1 scans registered projects", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    project = ProjectFixture.from_repo(tmp_dir, name: "cron-freshness")
    :ok = ProjectRegistry.register(project)

    output = """
    Dependency         Only      Current  Latest   Status
    req                          0.6.1    0.6.2    Update possible
    """

    Application.put_env(:harness, :dep_freshness_runner, fn "mix", ["hex.outdated"], ^tmp_dir ->
      {:ok, output}
    end)

    assert :ok = DepFreshnessPoller.perform(%Oban.Job{})
    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("cron-freshness")
    assert snapshot.outdated_count == 1
  end

  test "perform/1 tolerates skipped and failed project scans", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    skipped = ProjectFixture.from_repo("/tmp/harness-rust-freshness-cron", name: "cron-rust", language: :rust)
    failed = ProjectFixture.from_repo(tmp_dir, name: "cron-failed")

    :ok = ProjectRegistry.register(skipped)
    :ok = ProjectRegistry.register(failed)

    Application.put_env(:harness, :dep_freshness_runner, fn "mix", ["hex.outdated"], ^tmp_dir ->
      {:error, :hex_failed}
    end)

    assert :ok = DepFreshnessPoller.perform(%Oban.Job{})
    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("cron-rust")
    assert snapshot.language == "rust"
    assert Enum.any?(snapshot.rows, &(&1.name == "provider:rust" and &1.status == :skipped))
    assert {:ok, failed_snapshot} = DepFreshness.fetch_snapshot("cron-failed")
    assert Enum.any?(failed_snapshot.rows, &(&1.name == "provider:elixir" and &1.status == :skipped))
  end

  test "schedule/0 follows cron settings" do
    assert :ok = Settings.set_schedule("hourly", "test")
    assert DepFreshnessPoller.schedule() == "0 * * * *"
  end

  @spec restore_runner(term()) :: :ok
  defp restore_runner(nil), do: Application.delete_env(:harness, :dep_freshness_runner)
  defp restore_runner(runner), do: Application.put_env(:harness, :dep_freshness_runner, runner)
end
