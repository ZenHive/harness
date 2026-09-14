defmodule Harness.Dashboard.RunsAPITest do
  # async: false — starts a real in-flight run in the shared run registry.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  describe "GET /harness/api/runs" do
    test "lists a live run and counts it as in flight", %{conn: conn} do
      run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)
      assert await_running(run_id)

      body = conn |> get("/harness/api/runs") |> json_response(200)

      mine = Enum.find(body["runs"], &(&1["run_id"] == run_id))

      assert %{"state" => "running", "held" => false, "task_id" => "8"} = mine
      assert is_binary(mine["project"])
      assert Map.has_key?(mine, "agent")
      assert body["in_flight"] >= 1

      assert :ok = Run.cancel(run_id)
    end

    test "counts a lingering settled run as registered but not in flight", %{conn: conn} do
      run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)
      assert await_running(run_id)
      assert :ok = Run.cancel(run_id)
      assert await_state(run_id, :failed)

      body = conn |> get("/harness/api/runs") |> json_response(200)

      assert %{"state" => "failed"} = Enum.find(body["runs"], &(&1["run_id"] == run_id))
      settled_ids = for %{"state" => s, "run_id" => id} <- body["runs"], s in ["done", "failed"], do: id
      assert run_id in settled_ids
      assert body["in_flight"] == Enum.count(body["runs"], &(&1["state"] not in ["done", "failed"]))
    end

    test "returns an empty roster when nothing is registered", %{conn: conn} do
      body = conn |> get("/harness/api/runs") |> json_response(200)

      assert is_list(body["runs"])
      assert body["in_flight"] == Enum.count(body["runs"], &(&1["state"] not in ["done", "failed"]))
    end

    test "is GET-only — the router leaves other methods unrouted", %{conn: conn} do
      assert conn |> post("/harness/api/runs", %{}) |> Map.fetch!(:status) == 404
    end
  end

  defp start_run(overrides) do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo)

    opts =
      Keyword.merge(
        [
          base_dir: base,
          reviewer: FakeAdapter,
          reviewer_adapter_opts: [command: {:review, "approve"}],
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        ],
        overrides
      )

    item = %Item{id: "8", title: "Runs API", prompt: "do the thing", agent: :claude}
    {:ok, run_id, _pid} = RunSupervisor.start_run(item, project, FakeAdapter, opts)
    run_id
  end

  defp await_running(run_id), do: await_state(run_id, :running)

  defp await_state(run_id, state, tries \\ 150)

  defp await_state(_run_id, state, 0), do: flunk("run never reached #{inspect(state)}")

  defp await_state(run_id, state, tries) do
    case Run.status(run_id) do
      {:ok, %Status{state: ^state}} ->
        :ok

      _ ->
        Process.sleep(20)
        await_state(run_id, state, tries - 1)
    end
  end
end
