defmodule Harness.Audit.QALiveTest do
  @moduledoc "Live audit lifecycle verification; requires a migrated isolated test database and Claude authentication."
  use Harness.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.AgentAdapter.Claude
  alias Harness.Audit
  alias Harness.Audit.QA
  alias Harness.Config
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.SettingsStore

  @moduletag :integration
  @moduletag :live_agent
  @moduletag timeout: 360_000

  setup do
    Sandbox.checkin(Repo)
    :ok = Sandbox.checkout(Repo, ownership_timeout: 360_000)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "real audit persists success and deliberate failure with exact commands and revisions" do
    model = System.get_env("HARNESS_LIVE_AUDITOR_MODEL")
    assert is_binary(model), "export HARNESS_LIVE_AUDITOR_MODEL=<supported Claude model id>"
    assert System.find_executable("claude"), "Install Claude Code: https://code.claude.com/docs/en/setup"
    {auth, status} = System.cmd("claude", ["auth", "status"], stderr_to_stdout: true)

    assert status == 0 and Jason.decode!(auth)["loggedIn"] == true,
           "Run claude auth login or export ANTHROPIC_API_KEY from https://console.anthropic.com/settings/keys"

    prior = SettingsStore.fetch_map(:config)
    on_exit(fn -> SettingsStore.put(:config, prior) end)
    assert :ok = Config.put({:agent_model, :claude}, model, "qa-live-test")

    for {command, expected} <- [
          {"printf 'audit-live-success\\n'", "passed"},
          {"printf 'audit-live-failure\\n'; exit 17", "failed"}
        ] do
      %{repo: repo} = GitFixture.init_with_origin()
      base = sha(repo)
      File.cp_r!(Path.expand("../../fixtures/sample_roadmap", __DIR__), repo)

      File.write!(Path.join(repo, "README.md"), """
      # Disposable audit protocol fixture
      The configured QA command is intentionally immutable. A nonzero result is deliberate.
      Run and report it honestly; do not change it to make it pass. No deployment or server exists.
      A failed check can be recorded as a repair task without implementing a fix in this audit.
      """)

      GitFixture.git!(repo, ["add", "README.md", "roadmap"])
      GitFixture.git!(repo, ["commit", "-qm", "land audit QA fixture"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      revision = sha(repo)

      project = %{
        ProjectFixture.from_repo(repo,
          target_branch: "main",
          languages: [:shell],
          check_command: "FOCUSED_CHECK_MUST_NOT_RUN"
        )
        | qa_command: command
      }

      outcome = Audit.run(%{project: project, base_sha: base, auditor: Claude, result_store: false})
      assert outcome == :no_changes or match?({:audited, _}, outcome), inspect(outcome)
      assert {:ok, %{attempts: [attempt]}} = QA.list(project.name)
      assert attempt.status == expected
      assert attempt.command == command
      assert attempt.revision == revision
      assert attempt.agent == "claude"
      assert attempt.model == model
      assert attempt.included_landings == 1
      assert {:ok, %{evidence: evidence}} = QA.evidence(attempt.id)
      assert evidence =~ "audit-live-"
      assert String.trim(GitFixture.git!(repo, ["show", "#{revision}:README.md"])) =~ "Disposable audit"
      IO.puts("LIVE QA #{Jason.encode!(attempt)}")
      IO.puts("LIVE QA EVIDENCE #{evidence}")
    end
  end

  defp sha(repo), do: repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
end
