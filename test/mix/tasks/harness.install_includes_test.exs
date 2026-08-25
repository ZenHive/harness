defmodule Mix.Tasks.Harness.InstallIncludesTest do
  # async: false because Mix.Task run/reenable state is process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # Isolate each test's dest and avoid touching real ~/.claude
    dest = Path.join(tmp, "includes")
    src = locate_priv_source_for_test()
    {:ok, dest: dest, src: src}
  end

  test "installs the workflow include into --dest and prints action", %{dest: dest, src: src} do
    refute File.exists?(Path.join(dest, "harness-workflow.md"))

    output =
      capture_io(fn ->
        Mix.Task.reenable("harness.install_includes")
        assert :ok = Mix.Task.run("harness.install_includes", ["--dest", dest])
      end)

    target = Path.join(dest, "harness-workflow.md")
    assert File.regular?(target)
    assert output =~ "installed:"
    assert output =~ target

    # Content matches the source we ship
    assert File.read!(target) == File.read!(src)
  end

  test "re-running on identical content reports up-to-date (no backup)", %{dest: dest} do
    # First install
    capture_io(fn ->
      Mix.Task.reenable("harness.install_includes")
      Mix.Task.run("harness.install_includes", ["--dest", dest])
    end)

    target = Path.join(dest, "harness-workflow.md")
    mtime_before = File.stat!(target).mtime

    output =
      capture_io(fn ->
        Mix.Task.reenable("harness.install_includes")
        assert :ok = Mix.Task.run("harness.install_includes", ["--dest", dest])
      end)

    assert output =~ "up-to-date:"
    assert File.stat!(target).mtime == mtime_before
    # no timestamped bak created
    refute File.exists?(target <> ".bak-" <> "0")
  end

  test "changed content produces backup then updates (without --force)", %{dest: dest, src: src} do
    # Seed a different file
    target = Path.join(dest, "harness-workflow.md")
    File.mkdir_p!(dest)
    File.write!(target, "# old version\n")

    output =
      capture_io(fn ->
        Mix.Task.reenable("harness.install_includes")
        assert :ok = Mix.Task.run("harness.install_includes", ["--dest", dest])
      end)

    assert output =~ "updated (backup"
    assert File.regular?(target)
    assert File.read!(target) == File.read!(src)

    # A .bak- file was left next to it
    baks = Path.wildcard(target <> ".bak-*")
    assert match?([_], baks)
  end

  test "--force overwrites without creating backup", %{dest: dest, src: src} do
    target = Path.join(dest, "harness-workflow.md")
    File.mkdir_p!(dest)
    File.write!(target, "# force-old\n")

    output =
      capture_io(fn ->
        Mix.Task.reenable("harness.install_includes")
        assert :ok = Mix.Task.run("harness.install_includes", ["--dest", dest, "--force"])
      end)

    assert output =~ "updated (forced):"
    assert File.read!(target) == File.read!(src)
    assert Path.wildcard(target <> ".bak-*") == []
  end

  # --- helpers ---

  # Mirror the task's locate logic but prefer the tree copy we bootstrapped for the run.
  defp locate_priv_source_for_test do
    candidates = [
      Application.app_dir(:harness, "priv/includes/harness-workflow.md"),
      Path.join([File.cwd!(), "priv", "includes", "harness-workflow.md"])
    ]

    Enum.find(candidates, &File.regular?/1) ||
      raise "test could not locate bootstrapped priv/includes/harness-workflow.md; candidates: #{inspect(candidates)}"
  end
end
