defmodule Harness.Run.ReviewerSelectionTest do
  use Harness.RunCase, async: true

  describe "reviewer selection" do
    test "no installed cross-family reviewer settles failed without silently approving" do
      installed =
        Map.new(Harness.AgentRegistry.all(), fn module ->
          {module, module == Harness.AgentAdapter.Claude}
        end)

      :sys.replace_state(Harness.AgentRegistry, &%{&1 | installed: installed})
      on_exit(fn -> Harness.AgentRegistry.reset() end)

      result = run(reviewer: nil)

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} = result
      assert report =~ "No cross-family reviewer adapter available"
    end

    test "an explicit same-family reviewer is refused — the gate must be cross-family" do
      # item.agent is :claude; :claude as reviewer is the same family.
      result = run(reviewer: :claude)

      assert %Result{state: :failed, reason: {:review_stuck, report}} = result
      assert report =~ "same_family_reviewer"
    end

    test "a project-pinned same-family reviewer is refused" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :claude)
      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "same_family_reviewer"
    end

    test "a runtime reviewer override wins over a registration default" do
      # The override is applied at the ProjectRegistry read boundary (lookup/1),
      # not inside the run — so register, flip, look up the *effective* project,
      # then dispatch it. This is exactly how a real dispatch path resolves it.
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :codex)
      SettingsStoreMemory.reset(scope: :test_default)
      :ok = ProjectRegistry.register(project)

      on_exit(fn ->
        ProjectRegistry.unregister(project.name)
        SettingsStoreMemory.reset(scope: :test_default)
      end)

      assert :ok = LandingSettings.set_reviewer(project.name, :claude, "test")
      assert {:ok, %{reviewer: :claude} = effective} = ProjectRegistry.lookup(project.name)

      {run_id, pid} = start_with_project_reviewer(effective, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "same_family_reviewer"
    end

    test "a project-pinned reviewer-ineligible agent is refused" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :codex)
      codex = Codex
      SettingsStoreMemory.reset(scope: :test_default)
      assert :ok = AgentSettings.set_reviewer_eligible(:codex, false, "test")
      :sys.replace_state(Harness.AgentRegistry, &put_in(&1, [:installed, codex], true))

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: :test_default)
        Harness.AgentRegistry.reset()
      end)

      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "reviewer_unavailable"
      assert report =~ "Codex"
    end

    test "a project-pinned reviewer that is not installed is refused" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(), reviewer: :codex)
      codex = Codex
      SettingsStoreMemory.reset(scope: :test_default)
      :sys.replace_state(Harness.AgentRegistry, &put_in(&1, [:installed, codex], false))

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: :test_default)
        Harness.AgentRegistry.reset()
      end)

      {run_id, pid} = start_with_project_reviewer(project, [])

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} =
               await_result(run_id, pid)

      assert report =~ "reviewer_unavailable"
      assert report =~ "Codex"
    end

    test "an implementer-disabled but reviewer-eligible agent IS reviewer-dispatchable (reviewer-only)" do
      # Regression: a Claude pinned as the dedicated reviewer but disabled as an
      # implementer (`enabled? == false`) settled every run :review_stuck with
      # {:reviewer_unavailable, Claude} — reviewer_dispatchable?/1 wrongly ANDed
      # in the implementer-level enabled? flag, making "reviewer-only" (disabled
      # implementer + eligible reviewer) unexpressable. The two roles are
      # orthogonal: reviewer selection is governed by reviewer_eligible? alone.
      codex = Codex
      SettingsStoreMemory.reset(scope: :test_default)
      :sys.replace_state(Harness.AgentRegistry, &put_in(&1, [:installed, codex], true))

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: :test_default)
        Harness.AgentRegistry.reset()
      end)

      # Disabled as an implementer, still reviewer-eligible (the default).
      assert :ok = AgentSettings.set_enabled(:codex, false, "test")
      assert AgentSettings.reviewer_eligible?(:codex)
      refute AgentSettings.enabled?(:codex)

      # Dispatchable as a reviewer DESPITE the implementer disable.
      assert Run.reviewer_dispatchable?(codex)

      # Turning off reviewer-eligibility — the correct reviewer gate — bars it.
      assert :ok = AgentSettings.set_reviewer_eligible(:codex, false, "test")
      refute Run.reviewer_dispatchable?(codex)
    end

    test "auto-selection keeps an installed unavailable cross-family reviewer in the slate" do
      codex = Codex
      fake_bin = fake_codex_bin()
      prepend_path(fake_bin)
      installed = Map.new(Harness.AgentRegistry.all(), &{&1, &1 == codex})
      SettingsStoreMemory.reset(scope: :test_default)
      :sys.replace_state(Harness.AgentRegistry, &%{&1 | installed: installed})
      assert :ok = Harness.AgentRegistry.mark_unavailable(codex, :soft_hint)
      put_reviewer_model_env(codex: "gpt-5-codex")

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: :test_default)
        Harness.AgentRegistry.reset()
      end)

      result = run(reviewer: nil)

      assert %Result{state: :done, reason: :approved, reviewer_adapter: ^codex} = result
      refute Harness.AgentRegistry.available?(codex)
    end

    test "an explicit unavailable reviewer pin still dispatches when installed and eligible" do
      codex = Codex
      fake_bin = fake_codex_bin()
      prepend_path(fake_bin)
      SettingsStoreMemory.reset(scope: :test_default)
      :sys.replace_state(Harness.AgentRegistry, &put_in(&1, [:installed, codex], true))
      assert :ok = Harness.AgentRegistry.mark_unavailable(codex, :soft_hint)
      put_reviewer_model_env(codex: "gpt-5-codex")

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: :test_default)
        Harness.AgentRegistry.reset()
      end)

      result = run(reviewer: :codex)

      assert %Result{state: :done, reason: :approved, reviewer_adapter: ^codex} = result
      refute Harness.AgentRegistry.available?(codex)
    end

    test "prioritize_reviewers/2 sinks a high-rejection-rate reviewer below a cleaner one" do
      candidates = [{:codex, CodexReviewer}, {:cursor, CursorReviewer}, {:grok, GrokReviewer}]

      # codex rejects freely, grok never; cursor is unmeasured (defaults 0.0).
      rates = %{CodexReviewer => 0.8, GrokReviewer => 0.0}

      ordered = Run.prioritize_reviewers(candidates, rates)

      # grok (0.0) and the unmeasured cursor (0.0) keep registry order ahead of
      # the high-rejection codex, which sinks to last.
      assert ordered == [{:cursor, CursorReviewer}, {:grok, GrokReviewer}, {:codex, CodexReviewer}]
    end

    test "prioritize_reviewers/2 preserves registry order when there is no rejection data" do
      candidates = [{:codex, CodexReviewer}, {:cursor, CursorReviewer}]

      # Empty rates → every candidate defaults to 0.0 → stable sort is a no-op.
      assert Run.prioritize_reviewers(candidates, %{}) == candidates
    end

    test "a reviewer-ineligible agent is never auto-selected as the gate (Task 182)" do
      # A cross-family reviewer is normally auto-selected from the registry;
      # marking every agent reviewer-ineligible removes them all and settles
      # review_stuck rather than handing the gate to an ineligible agent. Proves
      # eligibility — not availability — gates selection.
      ineligible = Enum.map(Harness.AgentRegistry.agents(), fn {agent, _module} -> agent end)
      SettingsStoreMemory.reset(scope: :test_default)
      Enum.each(ineligible, &AgentSettings.set_reviewer_eligible(&1, false, "test"))

      on_exit(fn -> SettingsStoreMemory.reset(scope: :test_default) end)

      result = run(reviewer: nil)

      assert %Result{state: :failed, reason: {:review_stuck, report}, reviewer_adapter: nil} = result
      assert report =~ "No cross-family reviewer adapter available"
    end
  end
end
