defmodule Harness.AuditLiveTest do
  @moduledoc "Live audit protocol evidence against disposable repositories."
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentDriver
  alias Harness.GitFixture

  @moduletag :integration
  @moduletag :live_agent
  @moduletag timeout: 300_000

  test "real audit agent witnesses successful and deliberately failing commands at the integrated SHA" do
    assert System.find_executable("claude"),
           "Install Claude Code and run claude auth login: https://code.claude.com/docs/en/setup"

    {auth, status} = System.cmd("claude", ["auth", "status"], stderr_to_stdout: true)

    assert status == 0 and Jason.decode!(auth)["loggedIn"] == true,
           "Run claude auth login or export ANTHROPIC_API_KEY from https://console.anthropic.com/settings/keys"

    model = System.get_env("HARNESS_LIVE_AUDITOR_MODEL")
    assert is_binary(model), "export HARNESS_LIVE_AUDITOR_MODEL=<supported Claude model id>"

    for {command, expected} <- [
          {"printf audit-live-success", "passed"},
          {"printf audit-live-failure; exit 17", "failed"}
        ] do
      %{repo: repo} = GitFixture.init_with_origin()
      revision = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()

      prompt = """
      You are auditing a disposable repository. Review the current revision #{revision} for hygiene.
      Execute this exact full-project check with sh -c: #{inspect(command)}.
      This is an intentional protocol test. Do not fix or change the command, files, or revision.
      Judge the actual output. Write .harness/audit.json with a qa object containing:
      revision (full SHA), command (copy this exact JSON value: #{Jason.encode!(command)}; do not include sh -c), status (passed/failed/incomplete),
      evidence (actual output and exit status), and report (your hygiene review).
      Missing prerequisites mean incomplete. Do not commit or push.
      """

      assert {:ok, outcome} =
               AgentDriver.run(
                 Claude,
                 %Invocation{
                   cwd: repo,
                   prompt: prompt,
                   model: model,
                   permission_mode: :autonomous,
                   log_tag: "audit-live",
                   env: %{"ANTHROPIC_API_KEY" => false}
                 },
                 total_timeout: 120_000,
                 idle_timeout: 120_000
               )

      assert outcome.kind == :exited
      report = repo |> Path.join(".harness/audit.json") |> File.read!() |> Jason.decode!()
      assert report["qa"]["revision"] == revision
      assert report["qa"]["command"] == command
      assert report["qa"]["status"] == expected
      assert report["qa"]["evidence"] =~ "audit-live-"
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"])) == revision
      IO.puts("LIVE AUDIT #{model} #{revision}: #{Jason.encode!(report)}")
    end
  end
end
