defmodule Harness.Lander.WorkerTest do
  @moduledoc """
  Coverage for `Harness.Lander.Worker` — argument guards plus the
  runtime-landing-override regression: a project whose *registration* says
  `landing_policy: :manual` / no `target_branch` but whose persisted dashboard
  override says `:auto` must land using the override, not fail with
  `{:error, :no_target_branch}`.

  `async: false` — registers a fixture project in the global `ProjectRegistry`
  and mutates the `:harness, :landing_overrides` app env.
  """

  use ExUnit.Case, async: false

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.Lander.Worker
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Verification.Check

  @moduletag :tmp_dir

  describe "perform/1 — argument guards" do
    test "cancels when project_name is missing" do
      assert {:cancel, {:missing_arg, "project_name"}} =
               Worker.perform(%Oban.Job{args: %{"branch" => "harness/x"}})
    end

    test "cancels when branch is missing" do
      assert {:cancel, {:missing_arg, "branch"}} =
               Worker.perform(%Oban.Job{args: %{"project_name" => "demo"}})
    end
  end

  describe "perform/1 — runtime landing override (dashboard auto-land)" do
    setup %{tmp_dir: tmp_dir} do
      setup_landing_store(tmp_dir)
      fixture = git_fixture()
      project = register_project(fixture.repo, tmp_dir)

      Map.put(fixture, :project, project)
    end

    test "lands via the persisted override when the registered project has no target branch", ctx do
      :ok = LandingSettings.set(ctx.project.name, :auto, "main", "test")

      assert :ok = Worker.perform(%Oban.Job{args: land_args(ctx.project)})
      # origin/main advanced to the agent branch's tip — the land really happened.
      assert sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
    end

    test "without an override the raw registry project still has nothing to land onto", ctx do
      # Regression guard's control case: no override → the registry's
      # :manual/no-target project surfaces :no_target_branch (Oban retries).
      assert {:error, :no_target_branch} = Worker.perform(%Oban.Job{args: land_args(ctx.project)})
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  # Landing-settings store under a temp root (mirrors Harness.Landing.SettingsTest).
  defp setup_landing_store(tmp_dir) do
    prior_env = Application.get_env(:harness, :landing_overrides)
    prior_store = Application.get_env(:harness, :landing_settings)
    Application.put_env(:harness, :landing_settings, root: Path.join(tmp_dir, "landing-settings"))
    Application.put_env(:harness, :landing_overrides, %{})

    on_exit(fn ->
      restore(:landing_overrides, prior_env)
      restore(:landing_settings, prior_store)
    end)
  end

  # Bare origin + working clone with a settled harness/<run-id> branch
  # (shares Harness.LanderTest's fixture shape via GitFixture.init_with_origin/1).
  defp git_fixture do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()

    GitFixture.git!(repo, ["checkout", "-b", "harness/run-overlay"])
    File.write!(Path.join(repo, "feature.txt"), "work\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-m", "agent work"])
    branch_tip = sha(repo, "HEAD")
    GitFixture.git!(repo, ["checkout", "main"])

    %{origin: origin, repo: repo, branch_tip: branch_tip}
  end

  # Registered as :manual / no target — exactly how a project looks when
  # auto-land is flipped on from the dashboard rather than at registration.
  defp register_project(repo, tmp_dir) do
    project = %Project{
      name: "worker-overlay-demo",
      source: {:local, repo},
      check_stacks: [
        %CheckStack{name: :test, checks: [%Check{name: "ok", command: "true", args: []}], workdir: ""}
      ],
      roadmap_path: tmp_dir,
      landing_policy: :manual,
      target_branch: nil
    }

    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    project
  end

  defp land_args(project) do
    %{
      "project_name" => project.name,
      "run_id" => "run-overlay",
      "task_id" => "1",
      "agent" => "claude",
      "branch" => "harness/run-overlay",
      "land_attempt" => 1
    }
  end

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
