defmodule Harness.Cron.PendingDispatchTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Codex
  alias Harness.Chat.Tools
  alias Harness.Cron.PendingDispatch
  alias Harness.Dispatch
  alias Harness.Manifest
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item

  setup do
    ProjectRegistry.reset()
    PendingDispatch.reset()

    on_exit(fn ->
      Application.delete_env(:harness, :roadmap_ingest)
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :cron_dispatch_mode)
      PendingDispatch.reset()
    end)

    :ok
  end

  describe "park/4" do
    test "is idempotent over {project, task} and keys the id off the pair" do
      assert {:parked, record} = PendingDispatch.park("proj", "42", Codex, %{})
      assert record.id == "proj:42"
      assert record.adapter == Codex

      assert {:exists, ^record} = PendingDispatch.park("proj", "42", Codex, %{})
      assert [^record] = PendingDispatch.list()
    end

    test "lists records oldest first" do
      assert {:parked, a} = PendingDispatch.park("proj", "1", Codex, %{})
      assert {:parked, b} = PendingDispatch.park("proj", "2", Codex, %{})
      assert [^a, ^b] = PendingDispatch.list()
    end
  end

  describe "approve/1" do
    test "drains a parked record into Worker.enqueue and is idempotent" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-pending-approve", name: "pending-approve")
      assert :ok = ProjectRegistry.register(project)

      stub_ingest(parent)
      capture_inserts(parent)

      assert {:parked, record} =
               PendingDispatch.park("pending-approve", "42", Codex, %{"OPENAI_API_KEY" => false})

      assert {:ok, %{run_id: run_id, task_id: "42", project_name: "pending-approve", adapter: Codex}} =
               PendingDispatch.approve(record.id)

      assert is_binary(run_id)
      # The env scrub captured at park time is threaded into the enqueue, and the
      # task is re-ingested for the adapter's agent (codex).
      assert_received {:ingested, "42", :codex}

      assert_received {:inserted,
                       %{
                         item_id: "42",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                         env: %{"OPENAI_API_KEY" => false}
                       }}

      # Drained: gone from the store, and a second approval is a harmless no-op
      # (the guard that makes double-enqueue impossible).
      assert [] = PendingDispatch.list()
      assert {:error, :not_found} = PendingDispatch.approve(record.id)
    end

    test "keeps a claimed approval from being re-parked while enqueue is in flight" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-pending-claimed", name: "pending-claimed")
      assert :ok = ProjectRegistry.register(project)

      stub_ingest(parent)

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(parent, :enqueue_started)

        receive do
          :finish_enqueue -> {:ok, job}
        end
      end)

      assert {:parked, record} = PendingDispatch.park("pending-claimed", "42", Codex, %{})

      approver = Task.async(fn -> PendingDispatch.approve(record.id) end)
      assert_receive :enqueue_started

      assert {:exists, ^record} = PendingDispatch.park("pending-claimed", "42", Codex, %{})
      assert [] = PendingDispatch.list()

      send(approver.pid, :finish_enqueue)

      assert {:ok, %{task_id: "42", project_name: "pending-claimed", adapter: Codex}} =
               Task.await(approver)

      assert [] = PendingDispatch.list()
    end

    test "an unknown id is not_found" do
      assert {:error, :not_found} = PendingDispatch.approve("nope:1")
    end

    test "re-parks the record when the enqueue fails so the operator can retry" do
      project = ProjectFixture.from_repo("/tmp/harness-pending-fail", name: "pending-fail")
      assert :ok = ProjectRegistry.register(project)

      stub_ingest(self())
      Application.put_env(:harness, :oban_insert, fn _changeset -> {:error, :boom} end)

      assert {:parked, record} = PendingDispatch.park("pending-fail", "9", Codex, %{})
      assert {:error, :boom} = PendingDispatch.approve(record.id)

      assert [^record] = PendingDispatch.list()
    end
  end

  describe "Dispatch JSON surface" do
    test "dispatch-pending lists JSON-safe maps and filters by project" do
      project = ProjectFixture.from_repo("/tmp/harness-dispatch-pending", name: "dispatch-pending")
      assert :ok = ProjectRegistry.register(project)

      assert {:parked, record} = PendingDispatch.park("dispatch-pending", "7", Codex, %{})

      assert {:ok, %{pending: [entry]}} = Dispatch.pending()
      assert entry.id == record.id
      assert entry.project_name == "dispatch-pending"
      assert entry.task_id == "7"
      assert entry.adapter == "Harness.AgentAdapter.Codex"
      assert is_binary(entry.parked_at)

      # Filtering by a different project hides it.
      assert {:ok, %{pending: []}} = Dispatch.pending("other")
    end

    test "dispatch-approve drains and stringifies the adapter" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-dispatch-approve", name: "dispatch-approve")
      assert :ok = ProjectRegistry.register(project)

      stub_ingest(parent)
      capture_inserts(parent)

      assert {:parked, record} = PendingDispatch.park("dispatch-approve", "7", Codex, %{})

      assert {:ok, %{task_id: "7", project_name: "dispatch-approve", adapter: "Harness.AgentAdapter.Codex"}} =
               Dispatch.approve(record.id)

      assert {:ok, %{pending: []}} = Dispatch.pending()
      assert {:error, :not_found} = Dispatch.approve(record.id)
    end

    test "dispatch-pending and dispatch-approve are exposed on the MCP/chat tool surface" do
      tools = Manifest.mcp_tools()
      registry = Tools.build()

      assert Enum.find(tools, &(&1.name == "dispatch-pending")),
             "dispatch-pending should be on the MCP tool surface"

      assert Enum.find(tools, &(&1.name == "dispatch-approve")),
             "dispatch-approve should be on the MCP tool surface"

      assert %{module: Dispatch, function: :pending} = registry["dispatch-pending"]
      assert %{module: Dispatch, function: :approve} = registry["dispatch-approve"]
    end

    test "interactive dispatch is ungated by manual mode — only the cron path parks" do
      Application.put_env(:harness, :cron_dispatch_mode, %{"interactive-proj" => :manual})

      # The interactive entry point resolves the project itself and never consults
      # the cron dispatch mode: an unknown project errors at lookup, and nothing
      # is parked.
      assert {:error, {:unknown_project, "interactive-proj"}} =
               Dispatch.task("interactive-proj", "next", "codex")

      assert [] = PendingDispatch.list()
      assert {:ok, %{pending: []}} = Dispatch.pending()
    end
  end

  defp stub_ingest(parent) do
    Application.put_env(:harness, :roadmap_ingest, fn {:id, id}, opts ->
      agent = Keyword.get(opts, :agent)
      send(parent, {:ingested, id, agent})
      {:ok, %Item{id: id, title: "task #{id}", prompt: "prompt", agent: agent}}
    end)
  end

  defp capture_inserts(parent) do
    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)
  end
end
