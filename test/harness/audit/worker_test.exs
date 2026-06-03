defmodule Harness.Audit.WorkerTest do
  @moduledoc """
  Coverage for `Harness.Audit.Worker` — the thin Oban shell around
  `Harness.Audit.run/1`: arg validation, project resolution, the per-project
  uniqueness contract, and best-effort outcome routing (everything except a
  mechanical `{:error, _}` settles `:ok` so the audit queue keeps draining).

  `async: false` — registers projects in the global `ProjectRegistry`.
  """

  use ExUnit.Case, async: false

  alias Harness.Audit.Worker
  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  defp job(args), do: %Oban.Job{args: args}

  defp register!(%Project{} = project) do
    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    project
  end

  describe "unique_opts/0" do
    test "dedups per project while waiting only — executing audits never block new jobs" do
      opts = Worker.unique_opts()

      assert opts[:keys] == [:project_name]
      assert opts[:period] == :infinity
      assert Enum.sort(opts[:states]) == [:available, :scheduled]
    end
  end

  describe "perform/1 — arg validation" do
    test "cancels (never retries) on a missing project_name" do
      assert {:cancel, {:missing_arg, "project_name"}} = Worker.perform(job(%{"base_sha" => "abc"}))
    end

    test "cancels on a missing base_sha" do
      assert {:cancel, {:missing_arg, "base_sha"}} = Worker.perform(job(%{"project_name" => "demo"}))
    end

    test "cancels on a non-string base_sha" do
      assert {:cancel, {:missing_arg, "base_sha"}} =
               Worker.perform(job(%{"project_name" => "demo", "base_sha" => 123}))
    end

    test "cancels on a project that is not registered" do
      args = %{"project_name" => "ghost-project", "base_sha" => "abc"}

      assert {:cancel, {:unknown_project, "ghost-project"}} = Worker.perform(job(args))
    end
  end

  describe "perform/1 — best-effort outcome routing" do
    test "a skipped audit (GitHub source) settles :ok, not a retry" do
      project =
        register!(%Project{
          name: "audit-worker-github",
          source: {:github, "https://github.com/zenhive/demo"},
          roadmap_path: "/tmp",
          target_branch: "main"
        })

      args = %{"project_name" => project.name, "base_sha" => "abc"}

      assert :ok = Worker.perform(job(args))
    end

    test "an empty-range audit (:noop) settles :ok" do
      %{repo: repo} = GitFixture.init_with_origin()
      tip = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()

      project = register!(ProjectFixture.from_repo(repo, name: "audit-worker-noop", target_branch: "main"))

      args = %{
        "project_name" => project.name,
        "base_sha" => tip,
        "implementer" => "claude",
        "reviewer" => "codex"
      }

      assert :ok = Worker.perform(job(args))
    end

    test "a mechanical failure (unresolvable base_sha) surfaces {:error, _} for Oban to retry" do
      %{repo: repo} = GitFixture.init_with_origin()

      project = register!(ProjectFixture.from_repo(repo, name: "audit-worker-error", target_branch: "main"))

      args = %{
        "project_name" => project.name,
        "base_sha" => "0000000000000000000000000000000000000000"
      }

      assert {:error, {:range_check_failed, _reason}} = Worker.perform(job(args))
    end
  end
end
