defmodule Harness.Run.EvidenceTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Run.Evidence
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.Worktree

  @moduletag :tmp_dir

  test "snapshots screenshots and reports, preserving exact check references after cleanup", %{tmp_dir: root} do
    png = File.read!("test/fixtures/flutter_app/test/goldens/panel.png")
    path = ".harness/evidence/reviewer-1/linux.png"
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    File.write!(Path.join(root, path), png)
    File.write!(Path.join(root, ".harness/evidence/report.json"), ~s({"passed":true}))
    checks = %{"linux" => %{"passed" => true, "evidence" => [path]}}
    write_review(root, "approve", checks)
    assert {:ok, review} = Review.read(root, Review.identity("r", 1))
    assert review.evidence["count"] == 2
    assert review.evidence["missing"] == []
    assert review.evidence["errors"] == []
    assert review.evidence["files"][path]["media_type"] == "image/png"
    assert Base.decode64!(review.evidence["files"][path]["content"]) == png

    result = %Result{run_id: "r", task_id: "468", state: :done, reason: :approved, review: review}
    record = LogRecord.from_result(result, batch_id: "b", adapter: Harness.Test.FakeAdapter, duration_ms: 1)
    store = {ResultStore.Memory, root: root}
    assert :ok = ResultStore.record_run(record, store)
    File.rm_rf!(Path.join(root, ".harness"))
    assert {:ok, [saved]} = ResultStore.list_run_records(store, run_id: "r")
    assert saved.review_checks == checks
    assert saved.review_evidence == review.evidence
    assert {:ok, [summary]} = ResultStore.list_run_records(store, [])
    assert summary.review_evidence["count"] == 2
    refute Map.has_key?(summary.review_evidence, "files")
  end

  test "absent evidence has no invented images", %{tmp_dir: root} do
    assert %{"files" => %{}, "count" => 0, "errors" => [], "missing" => []} = Evidence.capture(root, %{})
  end

  test "missing and traversal references cannot support an approval, but rejection retains facts", %{tmp_dir: root} do
    for path <- [".harness/evidence/missing.png", "../secret", "/etc/passwd"] do
      checks = %{"ui" => %{"evidence" => [path]}}
      write_review(root, "approve", checks)
      assert {:error, {:malformed, {:evidence, %{"missing" => [^path]}}}} = Review.read(root, Review.identity("r", 1))
      write_review(root, "reject", checks)
      assert {:ok, %{evidence: %{"missing" => [^path]}}} = Review.read(root, Review.identity("r", 1))
    end
  end

  test "does not follow symlinks at the root, directories or files", %{tmp_dir: root} do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "must not be retained")
    File.mkdir_p!(Path.join(root, ".harness/evidence"))
    File.ln_s!(outside, Path.join(root, ".harness/evidence/link"))
    File.ln_s!(Path.join(outside, "secret"), Path.join(root, ".harness/evidence/secret"))
    assert %{"count" => 0, "errors" => [_, _]} = Evidence.capture(root, %{})
    File.rm_rf!(Path.join(root, ".harness"))
    File.ln_s!(outside, Path.join(root, ".harness"))
    assert %{"count" => 0, "errors" => [error]} = Evidence.capture(root, %{})
    assert error =~ "symlink"
  end

  test "oversized artifacts fail visibly", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, ".harness/evidence"))
    File.write!(Path.join(root, ".harness/evidence/large.log"), :binary.copy("x", 4_000_001))
    assert %{"count" => 0, "errors" => [error]} = Evidence.capture(root, %{})
    assert error =~ "byte limit"
  end

  test "staged evidence never appears in the delivery commit" do
    repo = GitFixture.init_repo()
    assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: GitFixture.tmp_base())
    File.mkdir_p!(Path.join(wt.path, ".harness/evidence"))
    File.write!(Path.join(wt.path, ".harness/evidence/screen.png"), "screen")
    File.write!(Path.join(wt.path, "screen.dart"), "screen change")
    GitFixture.git!(wt.path, ["add", ".harness/evidence/screen.png", "screen.dart"])
    assert {:ok, _sha} = Worktree.commit(wt, "fixture screen")
    tree = GitFixture.git!(wt.path, ["ls-tree", "-r", "--name-only", "HEAD"])
    assert tree =~ "screen.dart"
    refute tree =~ ".harness"
    assert File.exists?(Path.join(wt.path, ".harness/evidence/screen.png"))
  end

  @spec write_review(String.t(), String.t(), map()) :: :ok
  defp write_review(root, verdict, checks) do
    File.mkdir_p!(Path.join(root, ".harness"))

    File.write!(
      Path.join(root, Review.artifact_path()),
      Jason.encode!(%{
        verdict: verdict,
        report: "fixture",
        checks: checks,
        run_id: "r",
        review_attempt: "1"
      })
    )
  end
end
