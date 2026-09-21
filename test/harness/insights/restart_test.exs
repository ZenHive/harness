defmodule Harness.Insights.RestartTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Insights
  alias Harness.Insights.Document
  alias Harness.Insights.Store
  alias Harness.Repo

  @moduletag :integration

  test "committed observation progress and revisions survive a Repo process restart" do
    assert String.starts_with?(System.get_env("HARNESS_DB_NAME", ""), "harness_insights_"),
           "Use an isolated database: createdb harness_insights_test; env -u HARNESS_DATABASE_URL -u DATABASE_URL HARNESS_DB_NAME=harness_insights_test MIX_ENV=test mix ecto.migrate. See docs/verification/run-insights/README.md."

    start_supervised!(Repo)
    Sandbox.mode(Repo, :auto)
    old = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :repo_enabled, true)
    on_exit(fn -> Application.put_env(:harness, :repo_enabled, old) end)

    progress = %{
      "cursor" => "restart-run",
      "project_cursor" => "project-a",
      "qa_cursor" => Ecto.UUID.generate(),
      "last_success" => "2026-09-20T00:00:00Z"
    }

    finding = %{
      "id" => "restart",
      "projects" => ["restart"],
      "runs" => ["restart-run"],
      "citations" => [
        %{
          "excerpt" => "retained evidence",
          "revision" => "inline-revision",
          "project" => "restart",
          "provenance" => "referenced repair",
          "availability" => "available"
        }
      ]
    }

    :ok =
      Store.put_many([
        {"progress", "progress", progress},
        {"finding/restart", "finding", finding},
        {"revision/restart", "revision/restart", finding}
      ])

    original = Process.whereis(Repo)
    stop_supervised!(Repo)
    start_supervised!(Repo)
    Sandbox.mode(Repo, :auto)
    refute Process.whereis(Repo) == original
    assert Insights.status()["progress"] == progress
    assert Insights.history("restart")["revisions"] == [finding]
    assert Insights.findings("restart")["items"] == [finding]
    for id <- ["progress", "finding/restart", "revision/restart"], do: Repo.delete!(Repo.get!(Document, id))
  end
end
