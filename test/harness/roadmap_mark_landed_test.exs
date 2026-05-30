defmodule Harness.RoadmapMarkLandedTest do
  use ExUnit.Case, async: true

  alias Harness.Roadmap

  @moduletag :tmp_dir

  # Stubs the `rmap` binary with a shell script that records its argv, so the
  # writeback's CLI contract can be asserted without the real rmap (and without
  # depending on rmap's --shipped-in flag, which lands separately as rmap Task
  # 33). printf '%s\n' "$@" emits one argv element per line, in order.
  defp stub_rmap(tmp_dir) do
    script = Path.join(tmp_dir, "rmap")
    args_file = Path.join(tmp_dir, "rmap_args.txt")
    File.write!(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{args_file}'\nexit 0\n")
    File.chmod!(script, 0o755)
    {script, args_file}
  end

  describe "mark_landed/2" do
    test "builds the done + verified + shipped_in argv with delivered_by/implemented", %{tmp_dir: tmp_dir} do
      {script, args_file} = stub_rmap(tmp_dir)

      assert {:ok, _output} =
               Roadmap.mark_landed("7",
                 root: tmp_dir,
                 sha: "abc123",
                 delivered_by: "claude",
                 implemented: "did it",
                 rmap_bin: script
               )

      recorded = args_file |> File.read!() |> String.split("\n", trim: true)

      assert recorded == [
               "status",
               "7",
               "done",
               "--verified",
               "--shipped-in",
               "abc123",
               "--delivered-by",
               "claude",
               "--implemented",
               "did it",
               "--tasks-path",
               Path.join(tmp_dir, "roadmap/tasks.toml")
             ]
    end

    test "omits optional flags when not supplied", %{tmp_dir: tmp_dir} do
      {script, args_file} = stub_rmap(tmp_dir)

      assert {:ok, _output} = Roadmap.mark_landed("9", root: tmp_dir, sha: "deadbeef", rmap_bin: script)

      recorded = args_file |> File.read!() |> String.split("\n", trim: true)

      assert recorded == [
               "status",
               "9",
               "done",
               "--verified",
               "--shipped-in",
               "deadbeef",
               "--tasks-path",
               Path.join(tmp_dir, "roadmap/tasks.toml")
             ]
    end

    test "returns {:error, {:rmap_not_found, _}} when the binary is absent", %{tmp_dir: tmp_dir} do
      assert {:error, {:rmap_not_found, _bin}} =
               Roadmap.mark_landed("1", root: tmp_dir, sha: "x", rmap_bin: Path.join(tmp_dir, "nope-rmap"))
    end
  end
end
