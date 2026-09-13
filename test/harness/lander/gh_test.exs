defmodule Harness.Lander.GHTest do
  @moduledoc """
  Unit coverage for the mechanical `gh` wrapper.

  Stubs match shapes observed from `gh` 2.100.0 on this node: success prints
  the PR URL (`gh pr create --help`), `gh pr view --json` field names, and the
  unauthenticated exit-4 banner (live `gh pr create` / `gh auth status`).
  """
  use ExUnit.Case, async: false

  alias Harness.Lander.GH

  # Live `gh pr create` / `gh auth status` with no login, exit 4:
  @unauthenticated_output """
  To get started with GitHub CLI, please run:  gh auth login
  Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.
  """

  @pr_url "https://github.com/acme/harness/pull/7"

  setup do
    previous = Application.get_env(:harness, :gh_cmd)
    on_exit(fn -> restore(:gh_cmd, previous) end)
    :ok
  end

  describe "create_pr/1" do
    test "returns the URL printed on stdout (observed success contract)" do
      stub_gh(fn ["pr", "create" | _rest], _opts -> {@pr_url <> "\n", 0} end)

      assert {:ok, @pr_url} =
               GH.create_pr(
                 repo: "/tmp/repo",
                 base: "main",
                 head: "harness/run-x",
                 title: "task title",
                 body: "body"
               )
    end

    test "falls back to gh pr view --json url when stdout is not a URL" do
      stub_gh(fn
        ["pr", "create" | _rest], _opts -> {"Opening pull request in acme/harness\n", 0}
        ["pr", "view", "harness/run-x", "--json", "url"], _opts -> {Jason.encode!(%{"url" => @pr_url}), 0}
      end)

      assert {:ok, @pr_url} =
               GH.create_pr(
                 repo: "/tmp/repo",
                 base: "main",
                 head: "harness/run-x",
                 title: "t",
                 body: "b"
               )
    end

    test "classifies the observed unauthenticated banner" do
      stub_gh(fn _args, _opts -> {@unauthenticated_output, 4} end)

      assert {:error, {:gh_unauthenticated, output}} =
               GH.create_pr(
                 repo: "/tmp/repo",
                 base: "main",
                 head: "harness/run-x",
                 title: "t",
                 body: "b"
               )

      assert output =~ "gh auth login"
      assert output =~ "GH_TOKEN"
    end

    test "missing gh is :gh_not_found" do
      stub_gh(fn _args, _opts -> :not_found end)

      assert {:error, :gh_not_found} =
               GH.create_pr(
                 repo: "/tmp/repo",
                 base: "main",
                 head: "harness/run-x",
                 title: "t",
                 body: "b"
               )
    end
  end

  describe "view/3" do
    test "decodes observed JSON field names for an OPEN PR" do
      json = %{
        "url" => @pr_url,
        "state" => "OPEN",
        "mergeCommit" => nil,
        "mergedAt" => nil
      }

      stub_gh(fn ["pr", "view", @pr_url, "--json", "state,mergeCommit,mergedAt"], _opts ->
        {Jason.encode!(json), 0}
      end)

      assert {:ok, ^json} = GH.view(@pr_url, ["state", "mergeCommit", "mergedAt"])
    end

    test "decodes MERGED mergeCommit.oid (GraphQL Commit.oid)" do
      json = %{
        "state" => "MERGED",
        "mergeCommit" => %{"oid" => "abc123deadbeef"},
        "mergedAt" => "2026-09-13T01:00:00Z"
      }

      stub_gh(fn ["pr", "view", @pr_url, "--json", "state,mergeCommit,mergedAt"], _opts ->
        {Jason.encode!(json), 0}
      end)

      assert {:ok, decoded} = GH.view(@pr_url, ["state", "mergeCommit", "mergedAt"])
      assert decoded["state"] == "MERGED"
      assert decoded["mergeCommit"]["oid"] == "abc123deadbeef"
    end

    test "classifies the observed unauthenticated banner" do
      stub_gh(fn _args, _opts -> {@unauthenticated_output, 4} end)

      assert {:error, {:gh_unauthenticated, output}} = GH.view(@pr_url, ["state"])
      assert output =~ "gh auth login"
    end
  end

  @spec stub_gh(([String.t()], keyword() -> :not_found | {String.t(), integer()})) :: :ok
  defp stub_gh(fun), do: Application.put_env(:harness, :gh_cmd, fun)

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
