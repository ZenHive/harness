defmodule Harness.DepFreshness.IntegrationTest do
  @moduledoc """
  Runs dependency freshness providers against local fixtures and persists rows to Postgres.
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

  test "records cargo outdated rows for the Rust fixture project" do
    repo_root = Path.expand("../../support/fixtures/rust_project", __DIR__)
    project = ProjectFixture.from_repo(repo_root, name: "rust-fixture-self-scan", language: :rust)
    :ok = ProjectRegistry.register(project)

    assert :ok = DepFreshness.scan_project(project)

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("rust-fixture-self-scan")
    assert snapshot.language == "rust"
    assert snapshot.outdated_count <= length(snapshot.rows)

    assert Enum.any?(snapshot.rows, fn row ->
             row.name == "serde" and row.current_version == "1.0.0" and is_binary(row.latest_version)
           end)
  end
end
