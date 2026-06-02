defmodule Harness.Cron.RoadmapPollerTest do
  use ExUnit.Case, async: false

  alias Harness.AgentRegistry
  alias Harness.Cron.CapabilityBenchmarkScheduler
  alias Harness.Cron.RoadmapPoller
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Oban.Plugins.Cron

  setup do
    prior_cron_polling = Application.get_env(:harness, :cron_polling)
    prior_project_autonomy = Application.get_env(:harness, :cron_project_autonomy)

    AgentRegistry.reset()
    ProjectRegistry.reset()

    on_exit(fn ->
      restore_env(:cron_polling, prior_cron_polling)
      restore_env(:cron_project_autonomy, prior_project_autonomy)
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :roadmap_ready)
    end)

    :ok
  end

  test "master autonomy disabled by default, but the cron plugin still registers" do
    # The tick is always scheduled (Task 109): decoupling "tick is scheduled"
    # (unconditional) from "tick dispatches" (the runtime master gate) is what
    # lets the dashboard toggle take effect with no restart.
    refute RoadmapPoller.enabled?()
    assert Enum.any?(Harness.Oban.oban_opts()[:plugins], &cron_plugin?/1)
    assert {:cron, 1} in Harness.Oban.oban_opts()[:queues]
  end

  test "cron plugin carries the configured schedule" do
    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")

    assert RoadmapPoller.enabled?()
    assert {:cron, 1} in Harness.Oban.oban_opts()[:queues]

    crontab = cron_crontab()

    assert {"* * * * *", RoadmapPoller, [queue: :cron, max_attempts: 1]} in crontab
    assert CapabilityBenchmarkScheduler.cron_entry() in crontab
  end

  test "disabled poller does not read the roadmap or enqueue work" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-disabled", name: "cron-disabled")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ready, fn _project ->
      send(parent, :read)
      {:ok, [task("51", nil)]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    refute_received :read
    refute_received {:inserted, _job}
  end

  test "enabled tick dispatches the whole ready batch, routing each task to its agent" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-enabled", name: "cron-enabled", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{"cron-enabled" => true})

    # The whole dispatchable set is fanned out in one tick — one task with no
    # assignee (defaults :claude), plus tasks routed via `assignee`.
    Application.put_env(:harness, :roadmap_ready, fn p ->
      send(parent, {:ready, p.name})
      {:ok, [task("51", nil), task("52", "codex"), task("53", "cursor")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:ready, "cron-enabled"}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "cron-enabled",
                         item_id: "51",
                         adapter_module: "Elixir.Harness.AgentAdapter.Claude",
                         env: %{"ANTHROPIC_API_KEY" => false}
                       },
                       meta: %{harness_stage: "cron_poll"},
                       queue: "project_cron-enabled",
                       worker: "Harness.Run.Worker"
                     }}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         item_id: "52",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                         env: %{"OPENAI_API_KEY" => false}
                       }
                     }}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{item_id: "53", adapter_module: "Elixir.Harness.AgentAdapter.Cursor"} = cursor_args
                     }}

    refute Map.has_key?(cursor_args, :env)
  end

  test "operator config can disable subscription scrubs for metered API-key agents" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-metered", name: "cron-metered", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :cron_polling,
      enabled: true,
      schedule: "* * * * *",
      subscription_env_scrubs: %{claude: false, codex: %{}}
    )

    Application.put_env(:harness, :cron_project_autonomy, %{"cron-metered" => true})

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", nil), task("52", "codex")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:inserted, %{item_id: "51", adapter_module: "Elixir.Harness.AgentAdapter.Claude"} = claude_args}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"} = codex_args}
    refute Map.has_key?(claude_args, :env)
    refute Map.has_key?(codex_args, :env)
  end

  test "enabled tick skips human-assigned tasks" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-human", name: "cron-human", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{"cron-human" => true})

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", "human"), task("52", "codex")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received {:inserted, %{item_id: "51"}}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  test "a task routed to an unavailable agent is skipped; the rest of the batch still dispatches" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-unavailable", name: "cron-unavailable", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)
    # Claude (the default route) is out; the codex-routed task is unaffected.
    assert :ok = AgentRegistry.mark_unavailable(Harness.AgentAdapter.Claude, :quota)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{"cron-unavailable" => true})

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", nil), task("52", "codex")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received {:inserted, %{item_id: "51"}}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  test "master on dispatches only projects whose own autonomy flag is on" do
    parent = self()
    on_project = ProjectFixture.from_repo("/tmp/harness-cron-on", name: "cron-on", concurrency_cap: 10)
    off_project = ProjectFixture.from_repo("/tmp/harness-cron-off", name: "cron-off")
    assert :ok = ProjectRegistry.register(on_project)
    assert :ok = ProjectRegistry.register(off_project)

    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "* * * * *")
    Application.put_env(:harness, :cron_project_autonomy, %{"cron-on" => true, "cron-off" => false})

    Application.put_env(:harness, :roadmap_ready, fn p ->
      send(parent, {:ready, p.name})
      {:ok, [task("51", nil)]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    # Effective autonomy = master AND project: the enabled sibling's roadmap is
    # read, the disabled one's is never touched.
    assert_received {:ready, "cron-on"}
    refute_received {:ready, "cron-off"}
  end

  test "reports the next tick from the configured schedule" do
    Application.put_env(:harness, :cron_polling, enabled: true, schedule: "0 */2 * * *")

    assert {:ok, ~U[2026-05-27 02:00:00Z]} =
             RoadmapPoller.next_tick(~U[2026-05-27 00:15:00Z])
  end

  describe "task_agent/1" do
    test "routes adapter-backed assignees" do
      assert RoadmapPoller.task_agent(%{"assignee" => "codex", "model" => "claude-opus-4-7"}) == :codex
      assert RoadmapPoller.task_agent(%{"assignee" => "cursor"}) == :cursor
    end

    test "defaults missing assignee to claude without consulting model or markers" do
      assert RoadmapPoller.task_agent(%{"model" => "codex", "markers" => ["csr"]}) == :claude
      assert RoadmapPoller.task_agent(%{"assignee" => nil, "markers" => ["cx"]}) == :claude
    end

    test "preserves human assignee for autonomous-dispatch skip" do
      assert RoadmapPoller.task_agent(%{"assignee" => "human"}) == :human
    end

    test "falls back to claude for assignees with no harness adapter" do
      assert RoadmapPoller.task_agent(%{"assignee" => "droid"}) == :claude
    end
  end

  defp cron_plugin?({Cron, _opts}), do: true
  defp cron_plugin?(_plugin), do: false

  defp cron_crontab do
    Harness.Oban.oban_opts()
    |> Keyword.get(:plugins, [])
    |> Enum.find_value([], fn
      {Cron, crontab: entries} -> entries
      _ -> false
    end)
  end

  # A `rmap ready --dispatchable --fields id,assignee,markers` row.
  defp task(id, assignee), do: %{"id" => id, "assignee" => assignee, "markers" => []}

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
