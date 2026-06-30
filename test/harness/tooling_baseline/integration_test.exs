defmodule Harness.ToolingBaseline.IntegrationTest do
  @moduledoc """
  Scans the harness repo committed surface and persists conformance facts.
  """

  use Harness.DataCase, async: false

  alias Harness.DepFreshness
  alias Harness.DepFreshnessStore.Postgres, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ToolingBaseline.Item

  @moduletag :integration

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    Application.put_env(:harness, :dep_freshness_store, {Store, repo: Harness.Repo})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      Application.put_env(:harness, :dep_freshness_store, prev)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "records tooling baseline drift facts for the harness repo" do
    repo_root = File.cwd!()

    output = """
    Dependency         Only      Current  Latest   Status
    """

    runner = fn
      "mix", ["hex.outdated"], ^repo_root -> {:ok, output}
      _cmd, _args, _cwd -> {:error, :unexpected_runner}
    end

    project = ProjectFixture.from_repo(repo_root, name: "harness-baseline-scan", language: :elixir)
    :ok = ProjectRegistry.register(project)

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("harness-baseline-scan")
    assert %{} = snapshot.conformance
    assert is_integer(snapshot.conformance.drift_count)
    assert is_list(snapshot.conformance.items)
    assert Enum.any?(snapshot.conformance.items, &match?(%Item{}, &1))
    assert snapshot.conformance.drift_count == Enum.count(snapshot.conformance.items, &Item.drift?/1)
  end
end
