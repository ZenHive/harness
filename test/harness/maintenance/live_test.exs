defmodule Harness.Maintenance.LiveTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Maintenance
  alias Harness.Maintenance.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  @moduletag :live_agent
  @moduletag timeout: 600_000

  setup do
    if !System.find_executable("codex") do
      flunk(
        "Install Codex from https://developers.openai.com/codex/cli/ then run codex login and export HARNESS_MAINTENANCE_TEST_MODEL=gpt-6-astra"
      )
    end

    case System.cmd("codex", ["login", "status"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        flunk(
          "Run codex login, obtain access at https://chatgpt.com/codex, and export HARNESS_MAINTENANCE_TEST_MODEL=gpt-6-astra"
        )
    end
  end

  test "real provider refuses an unavailable explicit model without falling back" do
    repo = GitFixture.init_repo()

    assert {:error, :agent_failed} =
             Harness.Maintenance.Agent.assess(repo, %{"mode" => "discovery"}, %{
               "model" => "nonexistent-maintenance-contract-model",
               "deadline" => System.monotonic_time(:millisecond) + 30_000
             })
  end

  test "real agent discovers work, publishes once, and reports inaccessible evidence" do
    model = System.get_env("HARNESS_MAINTENANCE_TEST_MODEL")

    if !model do
      flunk(
        "Set export HARNESS_MAINTENANCE_TEST_MODEL=gpt-6-astra and run codex login; obtain access at https://chatgpt.com/codex. Run mix test --include live_agent test/harness/maintenance/live_test.exs"
      )
    end

    %{repo: repo} = GitFixture.init_with_origin(name: "maintenance-live")
    File.mkdir_p!(Path.join(repo, "roadmap"))
    File.write!(Path.join(repo, "ROADMAP.md"), "# Fixture Roadmap\n")

    File.write!(
      Path.join(repo, "roadmap/tasks.toml"),
      ~s(schema_version = 2\nproject = "maintenance-live"\ndefault_branch = "main"\nvision = "Disposable maintenance witness"\n[phases.1]\nname = "Maintenance"\norder = 1\nstatus = "pending"\n[bundles.maintenance]\nphase = 1\norder = 1\ndescription = "Fixture maintenance"\n\n[[task]]\nid = "1"\nphase = 1\nbundle = "maintenance"\nstatus = "done"\nimplemented = "Created disposable test fixture"\ndone_at = "2026-09-20"\ntitle = "Create disposable fixture"\nscores = { d = 1, b = 1, u = 1 }\n)
    )

    File.write!(
      Path.join(repo, "package.json"),
      ~s({"name":"maintenance-live","private":true,"dependencies":{"lodash":"4.17.20"}})
    )

    File.write!(
      Path.join(repo, "AGENTS.md"),
      "Analyze this disposable fixture. Cite provider-owned release/advisory evidence. Private advisories are unavailable: disclose this. This is a disposable, unpublished test fixture with no external consumers, no network integrations and no credential requirements for local dependency work. The only consumer is app.cjs, covered by test.cjs. Establish compatibility by running that test against old and updated dependencies in isolated copies. Do not invent performance measurements.\n"
    )

    File.write!(Path.join(repo, "app.cjs"), "const _ = require('lodash'); module.exports = values => _.sum(values);\n")

    File.write!(
      Path.join(repo, "test.cjs"),
      "const assert = require('node:assert/strict'); const total = require('./app.cjs'); assert.equal(total([1,2,3]), 6); assert.equal(total([]), 0); assert.equal(total([-1,1]), 0);\n"
    )

    GitFixture.git!(repo, ["add", "ROADMAP.md", "roadmap/tasks.toml", "package.json", "AGENTS.md", "app.cjs", "test.cjs"])
    GitFixture.git!(repo, ["commit", "-qm", "fixture"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    project = ProjectFixture.from_repo(repo, name: "maintenance-live", target_branch: "main")
    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)

    assert :ok = Maintenance.configure(project.name, true, 10_080, "codex", model, 300)
    old_models = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: model)
    # Writing a nil `old_models` back would leave :agent_model set to a non-list
    # and crash Config.agent_model/1 for every module that runs after this one.
    on_exit(fn ->
      if is_nil(old_models),
        do: Application.delete_env(:harness, :agent_model),
        else: Application.put_env(:harness, :agent_model, old_models)
    end)

    id = Ecto.UUID.generate()
    assert :ok == Maintenance.sweep(project.name, id), inspect(Store.get("pass/" <> id), limit: :infinity)
    findings = Maintenance.findings(project.name)["items"]
    assert Enum.any?(findings, &(&1["category"] in ["dependencies", "security"] and &1["evidence"] != ""))
    assert Maintenance.status(project.name)["state"] == "partial_evidence"
    assert Enum.any?(findings, &is_binary(&1["task_id"]))
    before = GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"])
    assert :ok == Maintenance.sweep(project.name, id), inspect(Store.get("pass/" <> id), limit: :infinity)
    assert GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"]) == before
    assert Store.get("pass/" <> id)["committed"]

    if output = System.get_env("HARNESS_MAINTENANCE_EVIDENCE") do
      File.write!(output, Jason.encode!(Store.get("pass/" <> id), pretty: true))
    end

    assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
  end
end
