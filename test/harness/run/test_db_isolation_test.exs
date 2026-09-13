defmodule Harness.Run.TestDbIsolationTest do
  use ExUnit.Case, async: false

  alias Harness.Project
  alias Harness.Run.TestDbIsolation

  @project %Project{name: "tapakly", source: {:local, "/tmp/tapakly"}, roadmap_path: "/tmp/tapakly", languages: [:elixir]}

  describe "env/2" do
    test "template opt-in partitions on the full run id" do
      recipe = %{
        "repo" => "App.Repo",
        "database" => "app_test",
        "template" => "harness_test_template_app",
        "extensions" => ["vector"]
      }

      project = %{@project | test_db_template: recipe}
      assert TestDbIsolation.env(project, "run-1-same") != TestDbIsolation.env(project, "run-2-same")
    end

    test "uses Phoenix's default MIX_TEST_PARTITION env with a DB-safe run suffix" do
      assert TestDbIsolation.env(@project, "run-1781945210210-a54845d6") == %{
               "MIX_TEST_PARTITION" => "_h_a54845d6"
             }
    end

    test "uses a project-specific env var name" do
      project = %{@project | test_db_isolation_env: "APP_TEST_PARTITION"}

      assert TestDbIsolation.env(project, "run-1781945210211-c001d00d") == %{
               "APP_TEST_PARTITION" => "_h_c001d00d"
             }
    end

    test "sanitizes suffix characters that are unsafe in database names" do
      assert TestDbIsolation.env(@project, "run-branch/foo.bar") == %{
               "MIX_TEST_PARTITION" => "_h_branch_foo_bar"
             }
    end

    test "honors explicit opt-outs" do
      scrub = %{"MIX_TEST_PARTITION" => false}

      assert TestDbIsolation.env(%{@project | test_db_isolation_env: false}, "run-a") == scrub
      assert TestDbIsolation.env(%{@project | test_db_isolation_env: :none}, "run-a") == scrub
      assert TestDbIsolation.env(%{@project | test_db_isolation_env: "none"}, "run-a") == scrub
      assert TestDbIsolation.env(%{@project | test_db_isolation_env: " "}, "run-a") == scrub
    end

    test "handles empty and punctuation-only run identifiers" do
      for id <- ["", "---", "run-///"] do
        assert TestDbIsolation.env(@project, id) == %{"MIX_TEST_PARTITION" => "_h_run"}
      end

      assert TestDbIsolation.env_name(%{@project | test_db_isolation_env: " APP_PARTITION "}) == {:ok, "APP_PARTITION"}
    end
  end

  test "preparation is opt-in and refuses a template with disabled isolation" do
    assert :ok = TestDbIsolation.prepare(@project, "/missing", "run-a")

    recipe = %{
      "repo" => "App.Repo",
      "database" => "app_test",
      "template" => "harness_test_template_app",
      "extensions" => ["vector"]
    }

    project = %{@project | test_db_template: recipe, test_db_isolation_env: false}
    assert {:error, {:test_db_template, message}} = TestDbIsolation.prepare(project, "/missing", "run-a")
    assert message =~ "requires enabled"

    assert {:error, {:test_db_template, invalid}} =
             TestDbIsolation.prepare(%{project | test_db_template: %{}}, "/missing", "run-a")

    assert invalid =~ "invalid recipe"
  end

  describe "teardown/3" do
    @describetag :tmp_dir

    test "does nothing for opted-out projects", %{tmp_dir: dir} do
      assert :ok = TestDbIsolation.teardown(%{@project | test_db_isolation_env: false}, dir, "run-a")
    end

    test "tolerates absent worktree paths and config", %{tmp_dir: dir} do
      assert :ok = TestDbIsolation.teardown(@project, nil, "run-a")
      File.write!(Path.join(dir, "mix.exs"), "")
      assert :ok = TestDbIsolation.teardown(@project, dir, "run-a")
    end

    test "logs command failures without interrupting settlement", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "config"))
      File.write!(Path.join(dir, "mix.exs"), "")
      File.write!(Path.join([dir, "config", "test.exs"]), "MIX_TEST_PARTITION")
      old_path = System.fetch_env!("PATH")
      on_exit(fn -> System.put_env("PATH", old_path) end)
      System.put_env("PATH", dir)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert :ok = TestDbIsolation.teardown(@project, dir, "run-a")
             end) =~ "teardown failed"

      File.write!(Path.join(dir, "mix"), "#!/bin/sh\necho failed\nexit 1\n")
      File.chmod!(Path.join(dir, "mix"), 0o755)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert :ok = TestDbIsolation.teardown(@project, dir, "run-a")
             end) =~ "teardown exited 1"
    end

    test "does nothing when the worktree does not advertise the isolation env", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "defmodule Fake.MixProject do\nend\n")
      File.mkdir_p!(Path.join(dir, "config"))
      File.write!(Path.join([dir, "config", "test.exs"]), "import Config\n")

      assert :ok = TestDbIsolation.teardown(@project, dir, "run-a")
    end

    test "drops the partitioned test database when the project honors the env", %{tmp_dir: dir} do
      capture = Path.join(dir, "drop-capture")
      fake_bin = Path.join(dir, "bin")
      fake_mix = Path.join(fake_bin, "mix")

      File.mkdir_p!(Path.join(dir, "config"))
      File.mkdir_p!(fake_bin)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Fake.MixProject do\nend\n")
      File.write!(Path.join([dir, "config", "test.exs"]), ~S|System.get_env("APP_TEST_PARTITION")|)

      File.write!(fake_mix, fake_mix_script())
      File.chmod!(fake_mix, 0o755)

      old_path = System.get_env("PATH", "")
      System.put_env("PATH", fake_bin <> ":" <> old_path)
      System.put_env("HARNESS_DROP_CAPTURE", capture)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        System.delete_env("HARNESS_DROP_CAPTURE")
      end)

      project = %{@project | test_db_isolation_env: "APP_TEST_PARTITION"}

      assert :ok = TestDbIsolation.teardown(project, dir, "run-1781945210212-deadbeef")

      assert File.read!(capture) == """
             ecto.drop --quiet
             test
             _h_deadbeef
             """
    end
  end

  @spec fake_mix_script() :: String.t()
  defp fake_mix_script do
    """
    #!/bin/sh
    printf '%s %s\\n' "$1" "$2" > "$HARNESS_DROP_CAPTURE"
    printf '%s\\n' "$MIX_ENV" >> "$HARNESS_DROP_CAPTURE"
    printf '%s\\n' "$APP_TEST_PARTITION" >> "$HARNESS_DROP_CAPTURE"
    """
  end
end
