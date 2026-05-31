defmodule Harness.ObanTrackedBranchesTest do
  @moduledoc """
  `Harness.Oban.tracked_landing_branches/1` — the observable guard behind the
  read-only-witness contract. Hits the real `oban_jobs` table, so it's tagged
  `:integration` (a live DB), matching how the rest of the Postgres/Oban layer is
  tested here. Run with `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Oban, as: HarnessOban
  alias Oban.Job

  @moduletag :integration

  # The test app runs with `repo_enabled: false` (offline suite), so this
  # DB-backed test starts its own Repo and checks out a sandbox connection.
  # Requires a migrated test DB: `MIX_ENV=test mix ecto.create ecto.migrate`.
  setup do
    start_supervised!(Harness.Repo)
    :ok = Sandbox.checkout(Harness.Repo)
  end

  # Inserts an oban_jobs row directly (not via Oban.insert, which runs inline in
  # test and would never persist an unfinished job), forcing the given state.
  defp insert_job(queue, args, state) do
    {:ok, job} =
      args
      |> Job.new(worker: Harness.Lander.Worker, queue: queue)
      |> Harness.Repo.insert()

    job |> Ecto.Changeset.change(state: state) |> Harness.Repo.update!()
  end

  describe "tracked_landing_branches/1" do
    test "returns branches with unfinished landing jobs, deduped and nil-filtered" do
      queue = HarnessOban.landing_queue_name("proj-#{System.unique_integer([:positive])}")
      "landing_" <> name = queue

      insert_job(queue, %{"branch" => "harness/a"}, "available")
      insert_job(queue, %{"branch" => "harness/a"}, "executing")
      insert_job(queue, %{"branch" => "harness/b"}, "retryable")
      insert_job(queue, %{"branch" => "harness/done"}, "completed")
      insert_job(queue, %{}, "available")
      insert_job("landing_other", %{"branch" => "harness/elsewhere"}, "available")

      assert Enum.sort(HarnessOban.tracked_landing_branches(name)) == ["harness/a", "harness/b"]
    end

    test "returns [] when the train is tracking nothing for the project" do
      assert HarnessOban.tracked_landing_branches("empty-#{System.unique_integer([:positive])}") == []
    end
  end
end
