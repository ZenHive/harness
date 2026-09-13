defmodule Harness.Lander.GHIntegrationTest do
  @moduledoc """
  Live `gh` contract for `:pr` landing.

  Opens a throwaway PR against a scratch branch on the repo named by
  `HARNESS_GH_PR_TEST_REPO`, asserts `gh pr view --json` URL/state, and pins a
  real already-exists error. Missing env, `gh`, or auth **flunks** with export
  instructions — never a silent skip.

  Excluded from the default suite (`@moduletag :integration`):

      export HARNESS_GH_PR_TEST_REPO=owner/repo
      gh auth login
      # or: export GH_TOKEN=...
      mix test --include integration test/harness/lander/gh_integration_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 180_000

  @env_repo "HARNESS_GH_PR_TEST_REPO"

  test "opens a throwaway PR and pins a live already-exists error" do
    repo = require_repo!()
    ensure_gh!()
    ensure_auth!()

    suffix = Integer.to_string(System.system_time(:millisecond))
    base = "harness-pr-test-base-#{suffix}"
    head = "harness-pr-test-head-#{suffix}"
    work = clone!(repo)

    try do
      create_branch!(work, base)
      create_head!(work, base, head)
      url = create_pr!(work, base, head, suffix)
      view = view_json!(url)

      assert view["url"] == url
      assert String.upcase(to_string(view["state"])) == "OPEN"
      assert view["mergeCommit"] in [nil, %{}] or is_map(view["mergeCommit"])
      assert view["mergedAt"] in [nil, ""]

      error = already_exists_error!(work, base, head)
      assert error.status != 0
      assert error.output =~ "already exists" or error.output =~ url
    after
      cleanup(work, base, head)
    end
  end

  @spec require_repo!() :: String.t()
  defp require_repo! do
    case System.get_env(@env_repo) do
      repo when is_binary(repo) and repo != "" ->
        repo

      _missing ->
        flunk("""
        Live gh PR integration requires a scratch GitHub repo the operator owns.

            export #{@env_repo}=owner/repo
            gh auth login
            # or:
            export GH_TOKEN=<github token with repo scope>

        Then:

            mix test --include integration test/harness/lander/gh_integration_test.exs
        """)
    end
  end

  @spec ensure_gh!() :: String.t()
  defp ensure_gh! do
    case System.find_executable("gh") do
      path when is_binary(path) ->
        path

      nil ->
        flunk("""
        `gh` is not on PATH. Install GitHub CLI, then authenticate:

            export #{@env_repo}=owner/repo
            gh auth login
            # or:
            export GH_TOKEN=<github token with repo scope>
        """)
    end
  end

  @spec ensure_auth!() :: :ok
  defp ensure_auth! do
    {_output, status} = System.cmd("gh", ["auth", "status"], stderr_to_stdout: true)

    if status == 0 do
      :ok
    else
      flunk("""
      `gh` is installed but not authenticated (observed live: exit 4 and
      "please run:  gh auth login" / populate GH_TOKEN).

          export #{@env_repo}=owner/repo
          gh auth login
          # or:
          export GH_TOKEN=<github token with repo scope>
      """)
    end
  end

  @spec clone!(String.t()) :: String.t()
  defp clone!(repo) do
    dest = Path.join(System.tmp_dir!(), "harness-gh-pr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    {output, status} = System.cmd("gh", ["repo", "clone", repo, dest], stderr_to_stdout: true)

    if status != 0 do
      File.rm_rf(dest)
      flunk("gh repo clone #{repo} failed (#{status}): #{output}")
    end

    dest
  end

  @spec create_branch!(String.t(), String.t()) :: :ok
  defp create_branch!(work, base) do
    git!(work, ["checkout", "-b", base])
    git!(work, ["push", "-u", "origin", base])
    :ok
  end

  @spec create_head!(String.t(), String.t(), String.t()) :: :ok
  defp create_head!(work, base, head) do
    git!(work, ["checkout", "-b", head, base])
    File.write!(Path.join(work, "harness-pr-test.txt"), "throwaway #{head}\n")
    git!(work, ["add", "harness-pr-test.txt"])

    git!(work, [
      "-c",
      "user.email=harness-test@example.com",
      "-c",
      "user.name=Harness Test",
      "commit",
      "-m",
      "harness pr test #{head}"
    ])

    git!(work, ["push", "-u", "origin", head])
    :ok
  end

  @spec create_pr!(String.t(), String.t(), String.t(), String.t()) :: String.t()
  defp create_pr!(work, base, head, suffix) do
    {output, status} =
      System.cmd(
        "gh",
        [
          "pr",
          "create",
          "--base",
          base,
          "--head",
          head,
          "--title",
          "harness pr test #{suffix}",
          "--body",
          "throwaway harness PR integration #{suffix}\n\nharness-run:gh-integration"
        ],
        cd: work,
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("gh pr create failed (#{status}): #{output}")
    end

    url =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(&1, "http"))

    if is_binary(url), do: url, else: flunk("gh pr create printed no URL: #{output}")
  end

  @spec view_json!(String.t()) :: map()
  defp view_json!(url) do
    {output, status} =
      System.cmd("gh", ["pr", "view", url, "--json", "url,state,mergeCommit,mergedAt"], stderr_to_stdout: true)

    if status != 0 do
      flunk("gh pr view --json failed (#{status}): #{output}")
    end

    Jason.decode!(output)
  end

  @spec already_exists_error!(String.t(), String.t(), String.t()) :: %{status: integer(), output: String.t()}
  defp already_exists_error!(work, base, head) do
    {output, status} =
      System.cmd(
        "gh",
        ["pr", "create", "--base", base, "--head", head, "--title", "dup", "--body", "dup"],
        cd: work,
        stderr_to_stdout: true
      )

    %{status: status, output: output}
  end

  @spec cleanup(String.t(), String.t(), String.t()) :: :ok
  defp cleanup(work, base, head) do
    _ = System.cmd("gh", ["pr", "close", head, "--delete-branch"], cd: work, stderr_to_stdout: true)
    _ = System.cmd("git", ["push", "origin", "--delete", base], cd: work, stderr_to_stdout: true)
    File.rm_rf(work)
    :ok
  end

  @spec git!(String.t(), [String.t()]) :: String.t()
  defp git!(work, args) do
    {output, status} = System.cmd("git", args, cd: work, stderr_to_stdout: true)

    if status != 0 do
      flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end

    output
  end
end
