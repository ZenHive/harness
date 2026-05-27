defmodule Harness.Dashboard.LiveTest do
  # Covers the unit-testable helpers inside `Harness.Dashboard.Live`. Full
  # LiveView mount + render is verified end-to-end in the browser per Task 50's
  # acceptance criteria — the standalone Endpoint is disabled in the test env
  # (`config :harness, :dashboard, enabled: false`) so a `Phoenix.LiveViewTest`
  # mount is not wired up here.

  use ExUnit.Case, async: true

  alias Harness.Dashboard.Live
  alias Harness.Run.Status

  defp run_entry(run_id, project_name \\ nil, bucket \\ :in_flight, opts \\ []) do
    status = %Status{
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      state: Keyword.get(opts, :state, :running),
      repair_attempts: Keyword.get(opts, :repair_attempts, 0),
      verdict_status: Keyword.get(opts, :verdict_status, nil)
    }

    base = %{status: status, bucket: bucket, detail: Keyword.get(opts, :detail, nil)}
    if project_name, do: Map.put(base, :project_name, project_name), else: base
  end

  describe "bucket_counts/1" do
    test "returns zeros when the snapshot has no runs" do
      assert Live.bucket_counts(%{runs: []}) == %{in_flight: 0, repairing: 0, green: 0, red: 0}
    end

    test "groups runs by their classified bucket" do
      snapshot = %{
        runs: [
          run_entry("a", nil, :in_flight),
          run_entry("b", nil, :in_flight),
          run_entry("c", nil, :repairing),
          run_entry("d", nil, :green),
          run_entry("e", nil, :red),
          run_entry("f", nil, :red)
        ]
      }

      assert Live.bucket_counts(snapshot) == %{in_flight: 2, repairing: 1, green: 1, red: 2}
    end
  end

  describe "filter_runs/2 (project filtering)" do
    test "no filter returns the runs unchanged" do
      runs = [run_entry("alpha/r1"), run_entry("beta/r2")]
      assert Live.filter_runs(runs, nil) == runs
    end

    test "filters by the run_id prefix convention (`<project>/<run>`)" do
      runs = [
        run_entry("alpha/r1"),
        run_entry("alpha/r2"),
        run_entry("beta/r1")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["alpha/r1", "alpha/r2"]
    end

    test "filters by the optional :project_name entry field" do
      runs = [
        run_entry("r-1", "alpha"),
        run_entry("r-2", "alpha"),
        run_entry("r-3", "beta")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["r-1", "r-2"]
    end
  end

  describe "trim_transcript/2 (bounded buffer)" do
    test "passes the buffer through untouched when under the cap" do
      buf = String.duplicate("x", 1_024)
      assert Live.trim_transcript(buf, 1_024) == {buf, 1_024}
    end

    test "trims to the configured 200 KiB tail when the buffer overflows" do
      cap = 200 * 1024
      buf = String.duplicate("a", cap) <> String.duplicate("b", 8 * 1024)
      bytes = byte_size(buf)

      {trimmed, trimmed_bytes} = Live.trim_transcript(buf, bytes)

      assert trimmed_bytes == cap
      assert byte_size(trimmed) == cap
      assert String.ends_with?(trimmed, String.duplicate("b", 8 * 1024))
    end
  end

  describe "verdict_label/1" do
    test "maps the three verdict values onto human strings" do
      assert Live.verdict_label(:pass) == "pass"
      assert Live.verdict_label(:fail) == "fail"
      assert Live.verdict_label(nil) == "—"
    end
  end
end
