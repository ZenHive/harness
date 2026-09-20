defmodule Harness.Projects.DispatchQATest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.Projects.DispatchQA
  alias Harness.Projects.DispatchQA.Catalog

  setup do
    capture_dir = Path.join(System.tmp_dir!(), "dispatch-qa-#{System.unique_integer([:positive])}")
    File.mkdir_p!(capture_dir)
    on_exit(fn -> File.rm_rf(capture_dir) end)
    %{capture_dir: capture_dir}
  end

  test "dry-run captures prior settings and does not mutate", %{capture_dir: capture_dir} do
    store = start_store([project("aave_sim", Catalog.entry("aave_sim").before_check_command)])

    assert {:ok, result} =
             DispatchQA.activate(
               names: ["aave_sim"],
               apply: false,
               capture_dir: capture_dir,
               lookup: lookup(store),
               upsert: upsert(store),
               qa_lookup: fn _ -> {:ok, %{attempts: []}} end
             )

    refute result.applied?
    assert File.exists?(result.capture_path)
    [planned] = result.projects
    assert planned.status == :qa_installed
    assert {:ok, live} = lookup(store).("aave_sim")
    assert live.qa_command == nil
    assert live.check_command == Catalog.entry("aave_sim").before_check_command
  end

  test "apply installs qa_command without reducing check_command until a QA pass", %{
    capture_dir: capture_dir
  } do
    before = Catalog.entry("aave_sim").before_check_command
    store = start_store([project("aave_sim", before)])

    assert {:ok, %{projects: [first]}} =
             DispatchQA.activate(activate_opts(store, capture_dir, apply: true))

    assert first.status == :qa_installed
    assert first.readback.qa_command == "mix precommit.full"
    assert first.readback.check_command == before
    assert first.readback.landing_policy == :auto
    assert first.readback.concurrency_cap == 4

    assert {:ok, %{projects: [held]}} =
             DispatchQA.activate(activate_opts(store, capture_dir, apply: true))

    assert held.status == :retained
    assert held.readback.check_command == before
  end

  test "dispatch switches only after a matching passed QA attempt", %{capture_dir: capture_dir} do
    entry = Catalog.entry("aave_sim")
    store = start_store([%{project("aave_sim", entry.before_check_command) | qa_command: entry.qa}])

    assert {:ok, %{projects: [switched]}} =
             DispatchQA.activate(
               activate_opts(store, capture_dir,
                 apply: true,
                 qa_lookup: fn _ ->
                   {:ok, %{attempts: [qa_pass(store, entry)]}}
                 end
               )
             )

    assert switched.status == :dispatch_switched
    assert switched.readback.check_command == entry.dispatch
    assert switched.readback.qa_command == entry.qa
  end

  test "idempotent once dispatch and QA already match", %{capture_dir: capture_dir} do
    entry = Catalog.entry("harness")
    store = start_store([%{project("harness", entry.dispatch) | qa_command: entry.qa}])

    assert {:ok, %{projects: [once]}} =
             DispatchQA.activate(
               activate_opts(store, capture_dir,
                 apply: true,
                 qa_lookup: fn _ -> {:ok, %{attempts: [qa_pass(store, entry)]}} end
               )
             )

    assert once.status == :unchanged

    assert {:ok, %{projects: [twice]}} =
             DispatchQA.activate(
               activate_opts(store, capture_dir,
                 apply: true,
                 qa_lookup: fn _ -> {:ok, %{attempts: [qa_pass(store, entry)]}} end
               )
             )

    assert twice.status == :unchanged
  end

  test "failed dispatch switch restores the prior check command", %{capture_dir: capture_dir} do
    entry = Catalog.entry("rmap")
    prior = %{project("rmap", entry.before_check_command) | qa_command: entry.qa}
    store = start_store([prior])

    fail_after_write = fn project ->
      Agent.update(store, &Map.put(&1, project.name, project))

      if project.check_command == entry.before_check_command do
        :ok
      else
        {:error, :upsert_denied}
      end
    end

    assert {:error, %{projects: [failed]}} =
             DispatchQA.activate(
               names: ["rmap"],
               apply: true,
               capture_dir: capture_dir,
               lookup: lookup(store),
               upsert: fail_after_write,
               qa_lookup: fn _ ->
                 {:ok, %{attempts: [qa_pass(store, entry)]}}
               end
             )

    assert failed.status == :failed
    assert {:ok, live} = lookup(store).("rmap")
    assert live.check_command == entry.before_check_command
    assert live.qa_command == entry.qa
  end

  test "unavailable projects are reported honestly", %{capture_dir: capture_dir} do
    store = start_store([])

    assert {:error, %{projects: [missing]}} =
             DispatchQA.activate(
               names: ["aave_sim"],
               apply: true,
               capture_dir: capture_dir,
               lookup: lookup(store),
               upsert: upsert(store),
               qa_lookup: fn _ -> {:ok, %{attempts: []}} end
             )

    assert missing.status == :unavailable
    assert missing.reason == "unregistered"
    assert missing.write_set == Catalog.entry("aave_sim").write_set
  end

  test "readback returns persisted commands without mutating", %{capture_dir: capture_dir} do
    entry = Catalog.entry("harness")
    store = start_store([%{project("harness", entry.dispatch) | qa_command: entry.qa}])

    [row] = DispatchQA.readback(names: ["harness"], lookup: lookup(store))
    assert row.available?
    assert row.check_command == entry.dispatch
    assert row.qa_command == "mix precommit.full"
    assert row.landing_policy == :auto

    assert {:ok, %{applied?: false}} =
             DispatchQA.activate(activate_opts(store, capture_dir, apply: false))
  end

  test "a mismatched QA command does not unlock a dispatch switch", %{capture_dir: capture_dir} do
    entry = Catalog.entry("ccxt-distill")
    store = start_store([%{project("ccxt-distill", entry.before_check_command) | qa_command: entry.qa}])

    assert {:ok, %{projects: [held]}} =
             DispatchQA.activate(
               activate_opts(store, capture_dir,
                 apply: true,
                 qa_lookup: fn _ ->
                   {:ok, %{attempts: [%{status: "passed", command: "npm run lint"}]}}
                 end
               )
             )

    assert held.status == :retained
    assert held.readback.check_command == entry.before_check_command
  end

  test "an Elixir project whose live check is still a full gate retains it until a QA pass", %{
    capture_dir: capture_dir
  } do
    entry = Catalog.entry("harness")
    store = start_store([%{project("harness", "mix precommit.full") | qa_command: entry.qa}])

    assert {:ok, %{projects: [held]}} =
             DispatchQA.activate(activate_opts(store, capture_dir, apply: true))

    assert held.status == :retained
    assert held.readback.check_command == "mix precommit.full"
  end

  test "capture files never collide and retain JSON booleans", %{capture_dir: dir} do
    store = start_store([project("harness", "mix check.dispatch")])
    opts = activate_opts(store, dir, apply: false)
    assert {:ok, first} = DispatchQA.activate(opts)
    assert {:ok, second} = DispatchQA.activate(opts)
    refute first.capture_path == second.capture_path
    result = (first.capture_path <> ".result.json") |> File.read!() |> Jason.decode!()
    assert result["applied?"] == false
  end

  test "a no-op persistence write cannot report installed QA", %{capture_dir: dir} do
    store = start_store([project("harness", "mix check.dispatch")])
    opts = store |> activate_opts(dir, apply: true) |> Keyword.put(:upsert, fn _ -> :ok end)
    assert {:error, %{projects: [failed]}} = DispatchQA.activate(opts)
    assert failed.status == :failed
    assert failed.reason =~ "readback_mismatch"
    assert failed.readback.qa_command == nil
  end

  test "failed restoration is reported without an invented readback", %{capture_dir: dir} do
    store = start_store([project("harness", "mix check.dispatch")])
    opts = store |> activate_opts(dir, apply: true) |> Keyword.put(:upsert, fn _ -> {:error, :offline} end)
    assert {:error, %{projects: [failed]}} = DispatchQA.activate(opts)
    assert failed.reason =~ "restoration_failed"
    assert failed.readback == nil
  end

  test "an old QA revision does not unlock the current checkout", %{capture_dir: dir} do
    entry = Catalog.entry("harness")
    store = start_store([%{project("harness", "mix check.dispatch") | qa_command: entry.qa}])

    opts =
      activate_opts(store, dir,
        apply: true,
        qa_lookup: fn _ ->
          {:ok, %{attempts: [Map.put(qa_pass(store, entry), :revision, "old-revision")]}}
        end
      )

    assert {:ok, %{projects: [held]}} = DispatchQA.activate(opts)
    assert held.status == :retained
    assert held.readback.check_command == "mix check.dispatch"
  end

  test "unknown project selections fail visibly", %{capture_dir: dir} do
    store = start_store([])

    assert {:error, %{projects: [%{status: :unavailable, name: "typo"}]}} =
             DispatchQA.activate(names: ["typo"], apply: true, capture_dir: dir, lookup: lookup(store))
  end

  @spec qa_pass(pid(), map()) :: map()
  defp qa_pass(store, entry) do
    {:ok, project} = lookup(store).(entry.name)
    {:ok, head} = Harness.Git.run(["rev-parse", "HEAD"], Project.repo_path(project))
    %{status: "passed", command: entry.qa, revision: String.trim(head), target_branch: project.target_branch}
  end

  @spec start_store([Project.t()]) :: pid()
  defp start_store(projects) do
    {:ok, pid} = Agent.start_link(fn -> Map.new(projects, &{&1.name, &1}) end)
    pid
  end

  @spec lookup(pid()) :: (String.t() -> {:ok, Project.t()} | {:error, term()})
  defp lookup(pid) do
    fn name ->
      case Agent.get(pid, &Map.get(&1, name)) do
        nil -> {:error, :unregistered}
        project -> {:ok, project}
      end
    end
  end

  @spec upsert(pid()) :: (Project.t() -> :ok)
  defp upsert(pid) do
    fn project ->
      Agent.update(pid, &Map.put(&1, project.name, project))
      :ok
    end
  end

  @spec activate_opts(pid(), String.t(), keyword()) :: keyword()
  defp activate_opts(store, capture_dir, extra) do
    name = Keyword.get(extra, :names, hd(Agent.get(store, &Map.keys/1)))

    [
      names: List.wrap(name),
      capture_dir: capture_dir,
      lookup: lookup(store),
      upsert: upsert(store),
      qa_lookup: Keyword.get(extra, :qa_lookup, fn _ -> {:ok, %{attempts: []}} end),
      apply: Keyword.get(extra, :apply, false)
    ]
  end

  @spec project(String.t(), String.t()) :: Project.t()
  defp project(name, check_command) do
    repo = GitFixture.init_repo()

    %Project{
      name: name,
      source: {:local, repo},
      roadmap_path: repo,
      languages: [:elixir],
      check_command: check_command,
      landing_policy: :auto,
      target_branch: "main",
      concurrency_cap: 4,
      reviewer: nil
    }
  end
end
