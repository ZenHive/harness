defmodule Harness.LiveAgentE2ETest do
  @moduledoc """
  Opt-in real CLI smoke test. Oban inserts are captured as in PipelineE2ETest;
  dispatch, both agents, reviewer verdict ingestion, git landing and rmap are real.

  Run: HARNESS_LIVE_REVIEWER_MODEL=<supported-pin> mix test.json --include live_agent
  Optional HARNESS_LIVE_IMPLEMENTER / HARNESS_LIVE_REVIEWER select codex or claude
  (defaults: codex / claude). HARNESS_LIVE_IMPLEMENTER_MODEL defaults to gpt-6-astra
  only for Codex; all other pins must be explicit. Pins are checked against the
  runtime catalog; the live invocation proves provider support and authentication.
  """

  use ExUnit.Case, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentRegistry
  alias Harness.GitFixture
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.ModelAvailability
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker, as: RunWorker
  alias Harness.Test.SettingsStoreMemory

  @moduletag :integration
  @moduletag :live_agent
  @moduletag :tmp_dir
  @moduletag timeout: 330_000
  @total_timeout 240_000

  @setup_instructions """
  Install: npm install -g @openai/codex @anthropic-ai/claude-code
  Authenticate both CLIs: codex login; claude auth login
  Install rmap from its Rust repository (cargo install --path .), and GNU coreutils (timeout).
  Required: export HARNESS_LIVE_REVIEWER_MODEL=<supported reviewer model id>
  Optional: export HARNESS_LIVE_IMPLEMENTER=codex HARNESS_LIVE_IMPLEMENTER_MODEL=gpt-6-astra
  Optional: export HARNESS_LIVE_REVIEWER=claude
  Only codex and claude are supported by this smoke test; they must differ.
  With a Claude implementer, HARNESS_LIVE_IMPLEMENTER_MODEL is also required.
  Run: mix test.json --include live_agent
  """

  setup %{tmp_dir: tmp_dir} do
    store_opts = [scope: tmp_dir]
    install_env(:settings_store, {SettingsStoreMemory, store_opts})
    on_exit(fn -> SettingsStoreMemory.reset(store_opts) end)
    install_env(:result_store, {ResultStore.Memory, root: Path.join(tmp_dir, "results")})
    implementer = selection!("IMPLEMENTER", "codex")
    reviewer = selection!("REVIEWER", "claude")

    assert MapSet.disjoint?(
             MapSet.new(implementer.adapter.capabilities().model_families),
             MapSet.new(reviewer.adapter.capabilities().model_families)
           ),
           "Implementer and reviewer must have different model families.\n" <> @setup_instructions

    for executable <- ["rmap", "timeout", implementer.name, reviewer.name] do
      if !System.find_executable(executable), do: flunk("Missing #{executable}.\n" <> @setup_instructions)
    end

    authenticate!(implementer.name)
    authenticate!(reviewer.name)
    implementer = resolve_model!(implementer, "IMPLEMENTER")
    reviewer = resolve_model!(reviewer, "REVIEWER")
    install_env(:reviewer_model, [{reviewer.agent, reviewer.model}])
    :ok = AgentSettings.set_enabled(implementer.agent, true, "live-agent-test")
    :ok = AgentSettings.set_reviewer_eligible(reviewer.agent, true, "live-agent-test")

    %{implementer: implementer, reviewer: reviewer}
  end

  test "real implementer and independent reviewer approve, land and verify the roadmap", ctx do
    started = System.monotonic_time(:millisecond)
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    base_dir = GitFixture.tmp_base()
    seed_roadmap!(repo)
    assert String.trim(GitFixture.git!(repo, ["remote", "get-url", "origin"])) == origin
    assert File.dir?(origin)

    project =
      ProjectFixture.from_repo(repo,
        name: "live-agent-#{System.unique_integer([:positive])}",
        languages: [:shell],
        landing_policy: :auto,
        target_branch: "main",
        check_command: "test \"$(cat smoke.txt)\" = live-agent-ok"
      )

    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    run_id = "run-#{project.name}"
    test_pid = self()

    install_env(:oban_insert, fn changeset ->
      send(test_pid, {:oban_insert, changeset})
      {:ok, %Oban.Job{}}
    end)

    install_env(:run_starter, fn item, run_project, adapter, opts ->
      RunSupervisor.start_run(
        item,
        run_project,
        adapter,
        Keyword.merge(opts,
          base_dir: base_dir,
          reviewer: ctx.reviewer.adapter,
          total_timeout: @total_timeout,
          lifetime_timeout: @total_timeout,
          idle_timeout: 60_000,
          terminal_linger: 100,
          env: %{"ANTHROPIC_API_KEY" => false, "ANTHROPIC_AUTH_TOKEN" => false, "OPENAI_API_KEY" => false}
        )
      )
    end)

    # Cancel before removing fixtures even if an assertion or the ExUnit timeout fires.
    on_exit(fn -> Harness.Run.cancel(run_id) end)

    IO.puts(
      "live_agent #{ctx.implementer.name}/#{ctx.implementer.model} -> " <>
        "#{ctx.reviewer.name}/#{ctx.reviewer.model}; total_timeout=#{@total_timeout}ms; " <>
        "lifetime_timeout=#{@total_timeout}ms"
    )

    job = %Oban.Job{
      id: System.unique_integer([:positive]),
      attempt: 1,
      args: %{
        "project_name" => project.name,
        "item_id" => "2",
        "adapter_module" => Atom.to_string(ctx.implementer.adapter),
        "requested_model" => ctx.implementer.model,
        "run_id" => run_id
      }
    }

    result = RunWorker.perform(job)

    assert result == :ok,
           "Live run failed (total_timeout=#{@total_timeout}ms, elapsed=" <>
             "#{System.monotonic_time(:millisecond) - started}ms): #{inspect(result)}\n" <>
             @setup_instructions

    assert {:ok, [approved]} = ResultStore.list_run_records(run_id: run_id)
    assert approved.state == :done
    assert approved.verdict == :approve
    assert approved.reviewer_adapter == ctx.reviewer.adapter
    assert approved.reviewer_model == ctx.reviewer.model
    assert approved.model == ctx.implementer.model
    assert approved.landed_sha == nil
    assert show_task(repo)["status"] == "in_progress"
    refute GitFixture.git!(origin, ["ls-tree", "--name-only", "main"]) =~ "smoke.txt"

    # A verdict alone cannot satisfy this test: execute the queued landing job.
    assert_receive {:oban_insert, landing}, 5_000
    assert Ecto.Changeset.get_field(landing, :queue) == "landing_" <> project.name
    args = Ecto.Changeset.get_field(landing, :args)
    assert args["run_id"] == run_id
    assert args["reviewer"] == ctx.reviewer.name
    approved_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "harness/" <> run_id]))
    assert :ok = LanderWorker.perform(%Oban.Job{args: args})

    assert {:ok, [landed]} = ResultStore.list_run_records(run_id: run_id)
    assert is_binary(landed.landed_sha)
    assert GitFixture.git!(origin, ["merge-base", "--is-ancestor", landed.landed_sha, "main"]) == ""
    assert GitFixture.git!(origin, ["merge-base", "--is-ancestor", approved_sha, "main"]) == ""
    assert GitFixture.git!(origin, ["show", "#{landed.landed_sha}:smoke.txt"]) == "live-agent-ok\n"

    task = show_task(repo)
    assert task["status"] == "done"
    assert task["shipped_in"] == landed.landed_sha
    assert task["verified"] == true
    assert task["delivered_by"] == ctx.implementer.name
    assert task["verified_by"] == ctx.reviewer.name
    assert task["verification_ref"] == "harness-run:" <> run_id
    assert System.monotonic_time(:millisecond) - started < 300_000
  end

  defp selection!(role, default) do
    name = System.get_env("HARNESS_LIVE_#{role}", default)
    assert name in ["codex", "claude"], "Unsupported #{role}: #{name}.\n" <> @setup_instructions
    agent = String.to_existing_atom(name)
    assert {:ok, adapter} = AgentRegistry.module_for_agent(agent)
    %{name: name, agent: agent, adapter: adapter}
  end

  defp authenticate!(name) do
    args = if name == "codex", do: ["login", "status"], else: ["auth", "status"]
    {output, status} = System.cmd("timeout", ["--kill-after=2s", "10s", name | args], stderr_to_stdout: true)
    if status != 0, do: flunk("#{name} authentication check failed (exit #{status}).\n" <> @setup_instructions)

    if name == "claude" do
      if !match?({:ok, %{"loggedIn" => true}}, Jason.decode(output)),
        do: flunk("Claude is unauthenticated.\n" <> @setup_instructions)
    end
  end

  defp resolve_model!(selection, role) do
    default = if role == "IMPLEMENTER" and selection.agent == :codex, do: "gpt-6-astra"
    model = System.get_env("HARNESS_LIVE_#{role}_MODEL", default)
    assert is_binary(model) and model != "", "Missing #{role} model pin.\n" <> @setup_instructions

    # Codex exposes its current catalog; Claude uses harness's maintained catalog.
    entries =
      if selection.agent == :codex do
        {output, status} =
          System.cmd("timeout", ["--kill-after=2s", "15s", "codex", "debug", "models"], stderr_to_stdout: true)

        assert status == 0, "Cannot resolve Codex models (exit #{status}).\n" <> @setup_instructions
        ModelAvailability.parse_catalog_output(:codex, output)
      else
        assert {:ok, catalog} = ModelAvailability.catalog(selection.agent)
        catalog
      end

    assert Enum.any?(entries, &(&1.id == model)),
           "Unsupported #{selection.name} pin #{model}; available: #{inspect(Enum.map(entries, & &1.id))}"

    assert ModelAvailability.available?(selection.agent, model)
    Map.put(selection, :model, model)
  end

  defp seed_roadmap!(repo) do
    File.cp_r!(Path.expand("../fixtures/sample_roadmap", __DIR__), repo)
    path = Path.join(repo, "roadmap/tasks.toml")

    content =
      path
      |> File.read!()
      |> String.replace("The next pending fixture task", "Create the live agent smoke marker")
      |> String.replace(
        "The pending task is the one rmap next returns",
        "smoke.txt contains exactly live-agent-ok followed by a newline"
      )
      |> String.replace(
        "The single pending fixture task. Used to prove ingestion fetches the next pending task and renders its prompt.",
        "Create smoke.txt containing exactly live-agent-ok and a trailing newline. Check it with the shell. This fixture needs no dependencies. Do not edit the roadmap or push; harness owns landing."
      )

    File.write!(path, content)
    File.write!(Path.join(repo, "ROADMAP.md"), "# Smoke\n\n<!-- TASKS:BEGIN -->\n<!-- TASKS:END -->\n")
    assert {_, 0} = System.cmd("rmap", ["render", "--tasks-path", path], stderr_to_stdout: true)
    GitFixture.git!(repo, ["add", "roadmap", "ROADMAP.md"])
    GitFixture.git!(repo, ["commit", "-qm", "seed live smoke task"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
  end

  defp show_task(repo) do
    assert {output, 0} = System.cmd("rmap", ["show", "2", "--json"], cd: repo, stderr_to_stdout: true)
    Jason.decode!(output)
  end

  defp install_env(key, value) do
    prior = Application.fetch_env(:harness, key)
    Application.put_env(:harness, key, value)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:harness, key, value)
        :error -> Application.delete_env(:harness, key)
      end
    end)
  end
end
