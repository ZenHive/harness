defmodule Harness.Cron.RoadmapPollerTest do
  use ExUnit.Case, async: false

  alias Harness.AgentRegistry
  alias Harness.Cron.RoadmapPoller
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Oban.Plugins.Cron

  setup do
    prior_cron_polling = Application.get_env(:harness, :cron_polling)

    AgentRegistry.reset()
    ProjectRegistry.reset()

    on_exit(fn ->
      restore_env(:cron_polling, prior_cron_polling)
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :queue_headroom?)
      Application.delete_env(:harness, :roadmap_ingest)
    end)

    :ok
  end

  test "disabled by default and omitted from Oban plugins" do
    refute RoadmapPoller.enabled?()
    refute Enum.any?(Harness.Oban.oban_opts()[:plugins], &cron_plugin?/1)
  end

  test "enabled config appends a cron plugin entry and cron queue" do
    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")

    assert RoadmapPoller.enabled?()
    assert {:cron, 1} in Harness.Oban.oban_opts()[:queues]

    assert {Cron, crontab: [{"* * * * *", RoadmapPoller, [queue: :cron, max_attempts: 1]}]} in Harness.Oban.oban_opts()[
             :plugins
           ]
  end

  test "disabled poller does not ingest or enqueue work" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-disabled", name: "cron-disabled")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      send(parent, :ingested)
      {:ok, item("51")}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    refute_received :ingested
    refute_received {:inserted, _job}
  end

  test "enabled tick ingests pending project work and enqueues a run worker job" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-enabled", name: "cron-enabled", concurrency_cap: 2)
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :queue_headroom?, fn ^project -> true end)

    Application.put_env(:harness, :roadmap_ingest, fn :next, opts ->
      send(parent, {:ingest, opts[:project_root]})
      {:ok, item("51")}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:ingest, "/tmp/harness-cron-enabled"}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "cron-enabled",
                         item_id: "51",
                         adapter_module: "Elixir.Harness.AgentAdapter.Claude"
                       },
                       meta: %{harness_stage: "cron_poll"},
                       queue: "project_cron-enabled",
                       worker: "Harness.Run.Worker"
                     }}
  end

  test "enabled tick skips enqueue when queue has no headroom" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-full", name: "cron-full")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :queue_headroom?, fn ^project -> false end)

    Application.put_env(:harness, :roadmap_ingest, fn :next, _opts ->
      send(parent, :ingested)
      {:ok, item("51")}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert_received :ingested
    refute_received {:inserted, _job}
  end

  test "enabled tick skips enqueue when the requested adapter is unavailable" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-unavailable", name: "cron-unavailable")
    assert :ok = ProjectRegistry.register(project)
    assert :ok = AgentRegistry.mark_unavailable(Harness.AgentAdapter.Claude, :quota)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :queue_headroom?, fn ^project -> true end)

    Application.put_env(:harness, :roadmap_ingest, fn :next, _opts ->
      send(parent, :ingested)
      {:ok, item("51")}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert_received :ingested
    refute_received {:inserted, _job}
  end

  test "reports the next tick from the configured schedule" do
    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "0 */2 * * *")

    assert {:ok, ~U[2026-05-27 02:00:00Z]} =
             RoadmapPoller.next_tick(~U[2026-05-27 00:15:00Z])
  end

  defp cron_plugin?({Cron, _opts}), do: true
  defp cron_plugin?(_plugin), do: false

  defp item(id), do: %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: :claude}

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
