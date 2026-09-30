defmodule Harness.FlutterLiveAgentTest do
  @moduledoc "Real implementer/reviewer dispatch for the Flutter evidence contract."
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings
  alias Harness.AgentRegistry
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Evidence

  @moduletag :integration
  @moduletag :live_agent
  @moduletag :tmp_dir
  @moduletag timeout: 3_000_000
  @budget 2_700_000

  test "independent agents change and verify a Flutter screen, retaining evidence outside git", %{tmp_dir: root} do
    for tool <- ["flutter", "python3", "xvfb-run", "adb", "emulator", "avdmanager", "codex", "claude"] do
      assert System.find_executable(tool), "Missing prerequisite: #{tool}; see docs/flutter-verification.md"
    end

    assert File.exists?("/dev/kvm"), "Missing prerequisite: /dev/kvm"
    assert System.get_env("HARNESS_ANDROID_IMAGE"), "Missing prerequisite: HARNESS_ANDROID_IMAGE"
    model = System.get_env("HARNESS_LIVE_REVIEWER_MODEL")
    assert model, "Set HARNESS_LIVE_REVIEWER_MODEL to an available Claude model; authenticate codex and claude."
    install_env(:settings_store, {Harness.Test.SettingsStoreMemory, scope: root})
    install_env(:reviewer_model, claude: model)
    :ok = Settings.set_enabled(:codex, true, "flutter-live-test")
    :ok = Settings.set_enabled(:claude, true, "flutter-live-test")
    :ok = Settings.set_reviewer_eligible(:claude, true, "flutter-live-test")
    assert {:ok, implementer} = AgentRegistry.module_for_agent(:codex)
    assert {:ok, reviewer} = AgentRegistry.module_for_agent(:claude)

    repo = GitFixture.init_repo()
    File.cp_r!("test/fixtures/flutter_app", repo)
    File.mkdir_p!(Path.join(repo, "scripts"))
    File.cp!("scripts/flutter-verify.py", Path.join(repo, "scripts/flutter-verify.py"))

    {output, status} =
      System.cmd(
        "flutter",
        ["create", "--no-pub", "--platforms=linux,android", "--project-name=harness_flutter_fixture", "."],
        cd: repo,
        stderr_to_stdout: true
      )

    assert status == 0, output

    GitFixture.git!(repo, [
      "add",
      "pubspec.yaml",
      "lib",
      "test",
      "integration_test",
      "test_driver",
      "scripts",
      "linux",
      "android",
      ".gitignore",
      ".metadata"
    ])

    GitFixture.git!(repo, ["commit", "-qm", "Flutter verification fixture"])

    item = %Item{
      id: "468",
      agent: :codex,
      title: "Change fixture screen title",
      prompt: """
      Change the app bar title from 'Verification fixture' to 'Verified client'. Add a widget assertion
      for the title. Use python3 scripts/flutter-verify.py --attempt implementer-1 to verify.
      Reviewer: independently run python3 scripts/flutter-verify.py --attempt reviewer-1, inspect
      all before/after screenshots and copy its checks.json entries into review.json checks.
      Do not approve without both Linux and Android screenshots and passing widget/golden tests.
      """,
      acceptance_criteria: [
        "Title is Verified client",
        "Reviewer runs analyze, widget, golden and Linux/Android integration tests and inspects screenshots"
      ]
    }

    store = {ResultStore.Memory, root: root}

    assert {:ok, run_id, pid} =
             Run.Supervisor.start_run(item, ProjectFixture.from_repo(repo, languages: [:dart]), implementer,
               base_dir: Path.join(root, "worktrees"),
               reviewer: reviewer,
               result_store: store,
               requested_model: System.get_env("HARNESS_LIVE_IMPLEMENTER_MODEL", "gpt-6-astra"),
               total_timeout: @budget,
               lifetime_timeout: @budget,
               progress_timeout: @budget,
               implementer_idle_timeout: @budget,
               reviewing_idle_timeout: @budget,
               idle_timeout: @budget,
               terminal_linger: 100
             )

    on_exit(fn -> if Process.alive?(pid), do: Run.cancel(run_id) end)
    assert_receive {:harness_run, ^run_id, result}, @budget
    assert result.state == :done, inspect(result.reason)
    assert result.review.verdict == :approve
    assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
    files = record.review_evidence["files"]

    for target <- ["linux", "android"], flow <- ["before", "after"] do
      path = ".harness/evidence/reviewer-1/#{target}/#{flow}.png"
      assert files[path]["media_type"] == "image/png"
      assert byte_size(Base.decode64!(files[path]["content"])) > 100
      assert path in Evidence.references(record.review_checks)
    end

    assert Enum.all?(record.review_checks, fn {_command, check} -> check["passed"] == true end)
    refute GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", "harness/#{run_id}"]) =~ ".harness/"
    assert GitFixture.git!(repo, ["show", "harness/#{run_id}:lib/main.dart"]) =~ "Verified client"
  end

  @spec install_env(atom(), term()) :: :ok
  defp install_env(key, value) do
    prior = Application.fetch_env(:harness, key)
    Application.put_env(:harness, key, value)

    on_exit(fn ->
      case prior do
        {:ok, original} -> Application.put_env(:harness, key, original)
        :error -> Application.delete_env(:harness, key)
      end
    end)
  end
end
