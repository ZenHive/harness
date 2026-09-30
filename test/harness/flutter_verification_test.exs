defmodule Harness.FlutterVerificationTest do
  @moduledoc "Live Flutter toolchain checks; missing prerequisites fail explicitly."
  use ExUnit.Case, async: false

  alias Harness.Run.Review

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 2_000_000

  test "real Flutter golden negative control records a failed check and retains diffs", %{tmp_dir: root} do
    flutter = System.find_executable("flutter")
    assert flutter, "Missing prerequisite: Flutter SDK; https://docs.flutter.dev/install"
    app = Path.join(root, "app")
    File.cp_r!("test/fixtures/flutter_app", app)
    {output, status} = System.cmd(flutter, ["pub", "get"], cd: app, stderr_to_stdout: true)
    assert status == 0, output
    {output, status} = System.cmd(flutter, ["test", "test/golden_test.dart"], cd: app, stderr_to_stdout: true)
    assert status == 0, "Baseline golden failed: #{output}"

    source = Path.join(app, "lib/main.dart")
    File.write!(source, source |> File.read!() |> String.replace("0xff1565c0", "0xffc01515"))
    {output, status} = System.cmd(flutter, ["test", "test/golden_test.dart"], cd: app, stderr_to_stdout: true)
    assert status != 0, "Negative control unexpectedly passed"
    diffs = Path.wildcard(Path.join(app, "test/failures/*.png"))
    assert diffs != [], "Flutter did not produce golden diffs: #{output}"
    evidence = Path.join(root, ".harness/evidence/negative-control")
    File.mkdir_p!(evidence)
    File.write!(Path.join(evidence, "golden.log"), output)
    for diff <- diffs, do: File.cp!(diff, Path.join(evidence, Path.basename(diff)))
    paths = evidence |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, root))

    File.write!(
      Path.join(root, Review.artifact_path()),
      Jason.encode!(%{
        verdict: "reject",
        report: "Deliberately changed panel pixels fail Flutter's golden comparator",
        run_id: "negative",
        review_attempt: "1",
        checks: %{"flutter test test/golden_test.dart" => %{passed: false, output: output, evidence: paths}}
      })
    )

    assert {:ok, review} = Review.read(root, Review.identity("negative", 1))
    assert review.verdict == :reject
    assert review.checks["flutter test test/golden_test.dart"]["passed"] == false
    assert review.evidence["count"] == length(paths)
    assert review.evidence["errors"] == []
  end

  test "Linux and Android integration produce screenshots for the fixture", %{tmp_dir: root} do
    assert System.find_executable("flutter"), "Missing prerequisite: Flutter SDK; https://docs.flutter.dev/install"
    app = Path.join(root, "app")
    File.cp_r!("test/fixtures/flutter_app", app)

    {output, status} =
      System.cmd(
        "flutter",
        ["create", "--no-pub", "--platforms=linux,android", "--project-name=harness_flutter_fixture", "."],
        cd: app,
        stderr_to_stdout: true
      )

    assert status == 0, output

    {output, status} =
      System.cmd("python3", ["scripts/flutter-verify.py", "--app", app, "--worktree", root, "--attempt", "reviewer-1"],
        stderr_to_stdout: true
      )

    assert status == 0, output

    for target <- ["linux", "android"], flow <- ["before", "after"] do
      assert File.exists?(Path.join(root, ".harness/evidence/reviewer-1/#{target}/#{flow}.png"))
    end
  end
end
