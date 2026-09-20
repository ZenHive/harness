defmodule Harness.SuiteHealth.RunnerTest do
  @moduledoc """
  Suite-health must drop the `_h_suite_health` partition on every path, including
  a raised suite command, and must not rewrite the witness when drop fails.
  """

  use ExUnit.Case, async: false

  alias Harness.ProjectFixture
  alias Harness.SuiteHealth.Runner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    write_project(dir)
    capture = install_fake_mix!(dir)
    project = ProjectFixture.from_repo(dir, name: "suite-health-db", languages: [:elixir])
    {:ok, dir: dir, project: project, capture: capture}
  end

  test "green prepare + run_suite drops the partition it created", %{dir: dir, project: project, capture: capture} do
    assert {:ok, result} = Runner.run_suite(project, dir, "abc123", runner: suite_runner(0, passing_json()))
    assert result.passed == true
    assert_drop_invoked(capture)
  end

  test "red suite still drops the partition", %{dir: dir, project: project, capture: capture} do
    output =
      ~s({"summary":{"failed":1,"result":"failed"},"tests":[{"state":"failed","name":"red","file":"test/x.exs","line":1}]})

    assert {:ok, result} = Runner.run_suite(project, dir, "abc123", runner: suite_runner(2, output))
    assert result.passed == false
    assert result.exit_code == 2
    assert_drop_invoked(capture)
  end

  test "cleanup runs when create succeeds and migrate fails", %{dir: dir, project: project, capture: capture} do
    runner = fn
      "mix", ["deps.get" | _], _, _ ->
        {"", 0}

      "mix", ["ecto.create" | _], _, env ->
        send(self(), {:created, env})
        {"", 0}

      "mix", ["ecto.migrate" | _], _, _ ->
        {"migrate boom", 1}

      cmd, args, _, _ ->
        flunk("unexpected #{cmd} #{inspect(args)}")
    end

    assert {:error, {:ecto_bootstrap_failed, 1, "migrate boom"}} =
             Runner.run_suite(project, dir, "abc123", runner: runner)

    assert_received {:created, env}
    assert {"MIX_TEST_PARTITION", "_h_suite_health"} in env
    assert_drop_invoked(capture)
  end

  test "a raised suite command still drops the partition", %{dir: dir, project: project, capture: capture} do
    runner = fn
      "mix", ["deps.get" | _], _, _ -> {"", 0}
      "mix", ["ecto.create" | _], _, _ -> {"", 0}
      "mix", ["ecto.migrate" | _], _, _ -> {"", 0}
      "mix", ["test.json" | _], _, _ -> raise "suite exploded"
      cmd, args, _, _ -> flunk("unexpected #{cmd} #{inspect(args)}")
    end

    assert_raise RuntimeError, "suite exploded", fn ->
      Runner.run_suite(project, dir, "abc123", runner: runner)
    end

    assert_drop_invoked(capture)
  end

  test "teardown failure is logged and does not change the witness", %{dir: dir, project: project, capture: capture} do
    System.put_env("HARNESS_DROP_BEHAVIOR", "fail")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, result} = Runner.run_suite(project, dir, "abc123", runner: suite_runner(0, passing_json()))
        assert result.passed == true
        assert result.exit_code == 0
      end)

    assert log =~ "teardown"
    assert_drop_invoked(capture)
  end

  test "isolation opt-out never invokes mix drop", %{dir: dir, capture: capture} do
    project =
      ProjectFixture.from_repo(dir,
        name: "suite-health-shared",
        languages: [:elixir],
        test_db_isolation_env: false
      )

    assert {:ok, result} = Runner.run_suite(project, dir, "abc123", runner: suite_runner(0, passing_json()))
    assert result.passed == true
    refute File.exists?(capture)
  end

  @spec write_project(String.t()) :: :ok
  defp write_project(dir) do
    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule SuiteHealthDb.MixProject do
      use Mix.Project
      def project, do: [app: :suite_health_db, version: "0.1.0"]
    end
    """)

    File.write!(Path.join([dir, "config", "test.exs"]), """
    import Config
    # Ecto
    System.get_env("MIX_TEST_PARTITION")
    """)

    :ok
  end

  @spec install_fake_mix!(String.t()) :: String.t()
  defp install_fake_mix!(dir) do
    capture = Path.join(dir, "drop-capture")
    fake_bin = Path.join(dir, "bin")
    fake_mix = Path.join(fake_bin, "mix")
    File.mkdir_p!(fake_bin)
    File.write!(fake_mix, fake_mix_script())
    File.chmod!(fake_mix, 0o755)

    old_path = System.get_env("PATH", "")
    System.put_env("PATH", fake_bin <> ":" <> old_path)
    System.put_env("HARNESS_DROP_CAPTURE", capture)
    System.put_env("HARNESS_DROP_BEHAVIOR", "ok")

    on_exit(fn ->
      System.put_env("PATH", old_path)
      System.delete_env("HARNESS_DROP_CAPTURE")
      System.delete_env("HARNESS_DROP_BEHAVIOR")
    end)

    capture
  end

  @spec fake_mix_script() :: String.t()
  defp fake_mix_script do
    """
    #!/bin/sh
    {
      printf '%s %s\\n' "$1" "$2"
      printf 'MIX_ENV=%s\\n' "$MIX_ENV"
      printf 'MIX_TEST_PARTITION=%s\\n' "$MIX_TEST_PARTITION"
    } > "$HARNESS_DROP_CAPTURE"

    case "${HARNESS_DROP_BEHAVIOR:-ok}" in
      fail)
        echo boom
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    """
  end

  @spec suite_runner(non_neg_integer(), String.t()) :: Harness.SuiteHealth.Bootstrap.runner()
  defp suite_runner(status, output) do
    fn
      "mix", ["deps.get" | _], _cwd, _env ->
        {"", 0}

      "mix", ["ecto.create" | _], _cwd, env ->
        send(self(), {:created, env})
        {"", 0}

      "mix", ["ecto.migrate" | _], _cwd, _env ->
        {"", 0}

      "mix", ["test.json" | _], _cwd, _env ->
        {output, status}

      cmd, args, _cwd, _env ->
        flunk("unexpected #{cmd} #{inspect(args)}")
    end
  end

  @spec passing_json() :: String.t()
  defp passing_json, do: ~s({"summary":{"failed":0,"result":"passed"},"tests":[]})

  @spec assert_drop_invoked(String.t()) :: :ok
  defp assert_drop_invoked(capture) do
    contents = File.read!(capture)
    assert contents =~ "run --no-start"
    assert contents =~ "MIX_ENV=test"
    assert contents =~ "MIX_TEST_PARTITION=_h_suite_health"
    :ok
  end
end
