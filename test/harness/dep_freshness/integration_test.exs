defmodule Harness.DepFreshness.IntegrationTest do
  @moduledoc """
  Runs the Elixir provider against this repo and persists rows to Postgres.
  """

  use Harness.DataCase, async: false

  alias Harness.DepFreshness
  alias Harness.DepFreshnessStore.Postgres, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

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

  test "records hex.outdated rows for the harness repo" do
    repo_root = File.cwd!()
    project = ProjectFixture.from_repo(repo_root, name: "harness-self-scan")
    :ok = ProjectRegistry.register(project)

    assert :ok = DepFreshness.scan_project(project)

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("harness-self-scan")
    assert is_integer(snapshot.outdated_count)
    assert snapshot.outdated_count <= length(snapshot.rows)
    assert snapshot.language == "elixir"
    assert [%{name: name} | _] = Enum.map(snapshot.rows, &Map.from_struct/1)
    assert is_binary(name)
  end
end
