defmodule Harness.AuditPostgresTest do
  @moduledoc """
  Postgres-backed audit watermark persistence coverage.

  The regular audit tests use a file-backed SettingsStore test double for speed;
  this module proves the same watermark key survives through the real
  `harness_settings` table.
  """

  use Harness.DataCase, async: false

  alias Harness.Audit
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.SettingsStore.Postgres, as: PostgresStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.TermCodec

  @moduletag :integration

  @watermark_file "audit_watermarks.term"
  @watermark_store_key "audit"

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
    prior_watermarks = Application.get_env(:harness, :audit_watermarks)

    root = Path.join(System.tmp_dir!(), "harness_audit_pg_#{System.unique_integer([:positive])}")

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo})
    Application.put_env(:harness, :audit_watermarks, root: root)

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:settings_store, prior_settings_store)
      restore(:audit_watermarks, prior_watermarks)
      File.rm_rf(root)
    end)

    {:ok, origin: origin, repo: repo, project: project, base_sha: sha(repo, "HEAD"), root: root}
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

    Application.put_env(:harness, :settings_store, {PostgresStore, repo: Repo})

    assert :noop =
             Audit.run(%{
               project: ctx.project,
               base_sha: ctx.base_sha,
               auditor: FakeAdapter,
               auditor_opts: [command: :echo]
             })
  end

  test "imports an existing audit_watermarks.term into Postgres on first read", ctx do
    landed_sha = land_work!(ctx)
    File.mkdir_p!(ctx.root)

    assert :ok =
             TermCodec.write_file(Path.join(ctx.root, @watermark_file), %{
               ctx.project.name => %{ctx.project.target_branch => landed_sha}
             })

    assert :noop = Audit.run(%{project: ctx.project, base_sha: ctx.base_sha})
    assert stored_watermark(ctx) == landed_sha
  end

  defp stored_watermark(ctx) do
    assert %Setting{payload: payload} = Repo.get(Setting, @watermark_store_key)
    assert {:ok, watermarks} = TermCodec.safe_binary_to_term(payload)
    get_in(watermarks, [ctx.project.name, ctx.project.target_branch])
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
