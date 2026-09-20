defmodule Harness.Maintenance.ControlTest do
  use ExUnit.Case, async: false

  alias Harness.Maintenance
  alias Harness.Maintenance.Store
  alias Harness.Maintenance.Tick
  alias Harness.Maintenance.Worker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    name = "maintenance-#{Ecto.UUID.generate()}"
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/maintenance", name: name))
    on_exit(fn -> ProjectRegistry.unregister(name) end)
    %{name: name}
  end

  test "disabled defaults, independent enablement and exact pins", %{name: name} do
    assert Maintenance.status(name)["state"] == "disabled"
    assert Maintenance.settings(name)["cadence_minutes"] == 10_080
    assert Maintenance.settings(name)["deadline_seconds"] == 1800
    assert {:error, :disabled} = Maintenance.sweep_now(name)
    assert {:error, :disabled} = Maintenance.sweep(name, "disabled")
    assert :ok = Maintenance.configure(name, true, 60, "codex", "gpt-6-astra", 60)
    assert {:error, :ephemeral_scheduler_unavailable} = Maintenance.sweep_now(name)
    assert {:error, :invalid_settings} = Maintenance.configure(name, true, 59, "codex", "gpt-6-astra", 60)
    assert {:error, :model_unavailable} = Maintenance.configure(name, true, 60, "codex", "absent", 60)
    assert :ok = Maintenance.configure(name, false, 60, "codex", "absent", 60)
    assert Maintenance.settings(name)["model"] == "absent"
    assert Harness.Insights.status()["settings"]["enabled"] == false
  end

  test "completed pass identities remain no-ops and failed source checks are visible", %{name: name} do
    :ok = Maintenance.configure(name, true, 60, "codex", "gpt-6-astra", 60)
    id = Ecto.UUID.generate()
    :ok = Store.put_many([{"pass/" <> id, "pass", %{"project" => name, "committed" => true}}])
    assert :ok = Maintenance.sweep(name, id)
    assert {:error, :source_unavailable} = Maintenance.sweep(name, Ecto.UUID.generate())
    assert Maintenance.status(name)["state"] == "failed"
    assert Maintenance.status(name)["progress"]["error"] == "source_unavailable"
    assert Maintenance.findings(name)["items"] == []
    assert Maintenance.history("missing")["finding"] == nil
  end

  test "scheduler leaves disabled repositories alone and reports unavailable durable scheduling", %{name: name} do
    assert :ok = Tick.perform(%Oban.Job{})
    :ok = Maintenance.configure(name, true, 60, "codex", "gpt-6-astra", 60)
    assert {:error, :ephemeral_scheduler_unavailable} = Tick.perform(%Oban.Job{})
    :ok = Maintenance.configure(name, false, 60, "codex", "gpt-6-astra", 60)
    assert :ok = Worker.perform(%Oban.Job{args: %{"project" => name, "pass_id" => "disabled-worker"}})
  end

  test "mechanical serialization excludes concurrent operations" do
    parent = self()

    first =
      Task.async(fn ->
        Store.serialized(fn ->
          send(parent, :entered)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :entered

    second =
      Task.async(fn ->
        Store.serialized(fn ->
          send(parent, :second)
          :ok
        end)
      end)

    refute_receive :second, 50
    send(first.pid, :release)
    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    assert_receive :second
  end
end
