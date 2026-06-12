defmodule Harness.AuditPostgresTest do
  @moduledoc """
  Audit watermark persistence coverage with the repo-enabled gate on.

  Audit watermarks share the Postgres-backed settings store with the other
  operator settings.
  """

  # async: false because DataCase uses SQL Sandbox shared mode for DB-backed collaborators.
  use Harness.DataCase, async: false

  alias Harness.Audit
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.SettingsStore
  alias Harness.SettingsStore.Postgres, as: PostgresStore

  @moduletag :integration

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  defp commit!(repo, file, message) do
    path = Path.join(repo, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, message <> "\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-q", "-m", message])
  end

  defp land_work!(ctx) do
    commit!(ctx.repo, "feature.txt", "landed work")
    GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
    sha(ctx.repo, "HEAD")
  end

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    project = ProjectFixture.from_repo(repo, name: "audit-pg", target_branch: "main")

    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo})

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:settings_store, prior_settings_store)
    end)

    {:ok, origin: origin, repo: repo, project: project, base_sha: sha(repo, "HEAD")}
  end

  test "clean audit watermark survives a simulated restart under repo_enabled true", ctx do
    landed_sha = land_work!(ctx)

    assert :no_changes =
             Audit.run(%{
               project: ctx.project,
               base_sha: ctx.base_sha,
               auditor: FakeAdapter,
               auditor_opts: [command: :echo]
             })

    assert stored_watermark(ctx) == landed_sha

    assert :noop =
             Audit.run(%{
               project: ctx.project,
               base_sha: ctx.base_sha,
               auditor: FakeAdapter,
               auditor_opts: [command: :echo]
             })
  end

  defp stored_watermark(ctx) do
    assert {:ok, watermarks} = SettingsStore.fetch(:audit)
    get_in(watermarks, [ctx.project.name, ctx.project.target_branch])
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
