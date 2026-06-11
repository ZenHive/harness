defmodule Harness.RoadmapMarkLandedTest do
  use ExUnit.Case, async: true

  alias Harness.Roadmap

  @moduletag :tmp_dir
  @concurrent_claim_ids ["45", "53", "55"]
  @race_sleep_seconds "0.2"

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

  defp racing_rmap(tmp_dir) do
    script = Path.join(tmp_dir, "racing-rmap")

    File.write!(script, """
    #!/bin/sh
    id="$2"
    status="$3"
    tasks_path=""

    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--tasks-path" ]; then
        tasks_path="$2"
        break
      fi

      shift
    done

    snapshot=$(cat "$tasks_path")
    sleep #{@race_sleep_seconds}
    tmp="${tasks_path}.$$"

    printf '%s\\n' "$snapshot" | awk -v target_id="$id" -v target_status="$status" '
      /^\\[\\[task\\]\\]/ { in_task = 1; matched = 0 }
      in_task && $1 == "id" && $3 == "\\"" target_id "\\"" { matched = 1 }
      in_task && matched && $1 == "status" {
        print "status = \\"" target_status "\\""
        next
      }
      { print }
    ' > "$tmp"

    mv "$tmp" "$tasks_path"
    echo "updated"
    """)

    File.chmod!(script, 0o755)
    script
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

  describe "mark_blocked/2" do
    test "builds the blocked + --reason argv with --tasks-path", %{tmp_dir: tmp_dir} do
      {script, args_file} = stub_rmap(tmp_dir)

      assert {:ok, _output} =
               Roadmap.mark_blocked("101",
                 root: tmp_dir,
                 reason: "land-cap exhausted after conflict x2",
                 rmap_bin: script
               )

      recorded = args_file |> File.read!() |> String.split("\n", trim: true)

      assert recorded == [
               "status",
               "101",
               "blocked",
               "--reason",
               "land-cap exhausted after conflict x2",
               "--tasks-path",
               Path.join(tmp_dir, "roadmap/tasks.toml")
             ]
    end

    test "returns {:error, {:rmap_not_found, _}} when the binary is absent", %{tmp_dir: tmp_dir} do
      assert {:error, {:rmap_not_found, _bin}} =
               Roadmap.mark_blocked("1", root: tmp_dir, reason: "x", rmap_bin: Path.join(tmp_dir, "nope-rmap"))
    end
  end

  describe "mark_in_progress/2" do
    test "builds the status in_progress argv with --tasks-path (no extra flags)", %{tmp_dir: tmp_dir} do
      {script, args_file} = stub_rmap(tmp_dir)

      assert {:ok, _output} =
               Roadmap.mark_in_progress("77",
                 root: tmp_dir,
                 rmap_bin: script
               )

      recorded = args_file |> File.read!() |> String.split("\n", trim: true)

      assert recorded == [
               "status",
               "77",
               "in_progress",
               "--tasks-path",
               Path.join(tmp_dir, "roadmap/tasks.toml")
             ]
    end

    test "returns {:error, {:rmap_not_found, _}} when the binary is absent", %{tmp_dir: tmp_dir} do
      assert {:error, {:rmap_not_found, _bin}} =
               Roadmap.mark_in_progress("1", root: tmp_dir, rmap_bin: Path.join(tmp_dir, "nope-rmap"))
    end

    test "serializes concurrent local in_progress claims so none are lost", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "roadmap"))
      File.write!(Path.join(tmp_dir, "roadmap/tasks.toml"), concurrent_tasks_toml())
      script = racing_rmap(tmp_dir)

      results =
        @concurrent_claim_ids
        |> Task.async_stream(
          fn id -> Roadmap.mark_in_progress(id, root: tmp_dir, rmap_bin: script) end,
          max_concurrency: length(@concurrent_claim_ids),
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      statuses = task_statuses(Path.join(tmp_dir, "roadmap/tasks.toml"))

      for id <- @concurrent_claim_ids do
        assert Map.fetch!(statuses, id) == "in_progress"
      end
    end
  end

  describe "mark_pending/2" do
    test "builds the status pending argv with --tasks-path (no extra flags)", %{tmp_dir: tmp_dir} do
      {script, args_file} = stub_rmap(tmp_dir)

      assert {:ok, _output} = Roadmap.mark_pending("88", root: tmp_dir, rmap_bin: script)

      recorded = args_file |> File.read!() |> String.split("\n", trim: true)

      assert recorded == [
               "status",
               "88",
               "pending",
               "--tasks-path",
               Path.join(tmp_dir, "roadmap/tasks.toml")
             ]
    end

    test "returns {:error, {:rmap_not_found, _}} when the binary is absent", %{tmp_dir: tmp_dir} do
      assert {:error, {:rmap_not_found, _bin}} =
               Roadmap.mark_pending("1", root: tmp_dir, rmap_bin: Path.join(tmp_dir, "nope-rmap"))
    end
  end

  defp concurrent_tasks_toml do
    """
    schema_version = 2
    project = "claim-race"
    default_branch = "main"
    vision = "Concurrent claim regression fixture."

    [phases.16]
    name = "Run lifecycle"
    order = 16
    status = "in_progress"

    [bundles.agent-gate]
    description = "Agent gate"
    order = 1
    phase = 16

    #{Enum.map_join(@concurrent_claim_ids, "\n", &task_toml/1)}
    """
  end

  defp task_toml(id) do
    """
    [[task]]
    id = "#{id}"
    phase = 16
    bundle = "agent-gate"
    status = "pending"
    title = "Task #{id}"
    scores = { d = 3, b = 7, u = 7 }
    body = "Claim me."
    created_at = "2026-06-09"
    """
  end

  defp task_statuses(tasks_path) do
    tasks_path
    |> File.read!()
    |> String.split("[[task]]")
    |> Enum.reduce(%{}, fn block, acc ->
      with [_, id] <- Regex.run(~r/id = "([^"]+)"/, block),
           [_, status] <- Regex.run(~r/status = "([^"]+)"/, block) do
        Map.put(acc, id, status)
      else
        _ -> acc
      end
    end)
  end
end
