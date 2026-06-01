defmodule Harness.ObanQueueBootstrapTest do
  @moduledoc """
  Regression for Task 133: a registered project's dispatch + landing queues must
  actually start when Oban is running.

  The pre-fix guard in `Harness.Oban.ensure_project_queue/1` was
  `Process.whereis(Harness.Oban)`, which is *always* nil — Oban registers its
  instance through `Oban.Registry` (a `{:via, ...}` name), never as a globally
  named process. So the guard short-circuited every start, queues never left
  `[:cron]` at boot, and cron-enqueued `Run.Worker` jobs sat `available`
  forever (autonomous dispatch was inert). The fix swaps in `Oban.whereis/1`.

  Tagged `:integration`: the offline suite runs Oban `testing: :inline`, which
  makes `queues_enabled?/0` false and disables dynamic queue starts, so the path
  this guards can only be exercised against a real Oban instance. Requires a
  migrated test DB (`MIX_ENV=test mix ecto.create ecto.migrate`); run with
  `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  @moduletag :integration

  @eventually_tries 100
  @eventually_delay_ms 20

  setup do
    start_supervised!(Harness.Repo)
    Sandbox.checkout(Harness.Repo)
    # Oban's producers run in their own processes under the Oban supervisor, so
    # they need to share this test's sandbox connection.
    Sandbox.mode(Harness.Repo, {:shared, self()})

    # The offline suite configures Oban `testing: :inline`, which short-circuits
    # `queues_enabled?/0`. Boot a real (non-testing) Oban named `Harness.Oban`
    # — the exact name `oban_running?/0` checks via `Oban.whereis/1`. The
    # in-memory Isolated notifier avoids LISTEN/NOTIFY against the sandbox.
    prev = Application.get_env(:harness, Oban)

    Application.put_env(:harness, Oban,
      name: HarnessOban,
      repo: Harness.Repo,
      notifier: Oban.Notifiers.Isolated,
      stage_interval: :infinity,
      queues: [],
      plugins: false
    )

    on_exit(fn -> Application.put_env(:harness, Oban, prev) end)

    start_supervised!({Oban, Application.get_env(:harness, Oban)})

    ProjectRegistry.reset()
    on_exit(fn -> ProjectRegistry.reset() end)
    :ok
  end

  test "register/1 starts the project's dispatch and landing queues" do
    name = "q133-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo("/tmp/harness-#{name}", name: name, concurrency_cap: 3)

    :ok = ProjectRegistry.register(project)

    # `Oban.start_queue/2` dispatches to the Midwife asynchronously, so poll the
    # running producers rather than asserting synchronously.
    assert_eventually(fn ->
      running = HarnessOban |> Oban.check_all_queues() |> MapSet.new(& &1.queue)
      assert MapSet.member?(running, HarnessOban.queue_name(project))
      assert MapSet.member?(running, HarnessOban.landing_queue_name(project))
    end)
  end

  defp assert_eventually(fun, tries \\ @eventually_tries)

  defp assert_eventually(fun, tries) when tries > 1 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(@eventually_delay_ms)
      assert_eventually(fun, tries - 1)
  end

  defp assert_eventually(fun, 1), do: fun.()
end
