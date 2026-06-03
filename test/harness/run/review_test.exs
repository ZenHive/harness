defmodule Harness.Run.ReviewTest do
  @moduledoc """
  Unit coverage for `Harness.Run.Review` — the mechanical reader of the
  reviewer AI's `.harness/review.json` verdict artifact. The artifact IS the
  gate of the agent-gate workflow, so every read outcome matters: approve,
  reject, missing file, malformed JSON, and the ratings passthrough.
  """

  use ExUnit.Case, async: true

  alias Harness.Run.Review

  doctest Review

  describe "parse/1 — verdicts" do
    test "an approve artifact parses to verdict :approve with its report" do
      json = ~s({"verdict": "approve", "report": "checks green, two nits fixed inline"})

      assert {:ok, %Review{verdict: :approve, report: "checks green, two nits fixed inline"}} =
               Review.parse(json)
    end

    test "a reject artifact parses to verdict :reject with its report" do
      json = ~s({"verdict": "reject", "report": "worktree contains no salvageable work"})

      assert {:ok, %Review{verdict: :reject, report: "worktree contains no salvageable work"}} =
               Review.parse(json)
    end

    test "an unknown verdict string is malformed, not coerced" do
      assert {:error, {:malformed, {:invalid_verdict, "maybe"}}} =
               Review.parse(~s({"verdict": "maybe", "report": "on the fence"}))
    end

    test "a non-string verdict is malformed" do
      assert {:error, {:malformed, {:invalid_verdict, true}}} =
               Review.parse(~s({"verdict": true}))
    end
  end

  describe "parse/1 — report and ratings tolerance" do
    test "a missing report defaults to an empty string" do
      assert {:ok, %Review{verdict: :approve, report: ""}} = Review.parse(~s({"verdict": "approve"}))
    end

    test "a non-string report is ignored, not crashed on" do
      assert {:ok, %Review{report: ""}} = Review.parse(~s({"verdict": "approve", "report": 42}))
    end

    test "ratings ride through verbatim as a string-keyed map" do
      json =
        ~s({"verdict": "approve", "report": "solid", "ratings": ) <>
          ~s({"performance": 8, "truthfulness": 9, "code_quality": 7, "idiom": 8}})

      assert {:ok, %Review{ratings: ratings}} = Review.parse(json)

      assert ratings == %{
               "performance" => 8,
               "truthfulness" => 9,
               "code_quality" => 7,
               "idiom" => 8
             }
    end

    test "missing or non-map ratings default to an empty map" do
      assert {:ok, %Review{ratings: %{}}} = Review.parse(~s({"verdict": "approve"}))
      assert {:ok, %Review{ratings: %{}}} = Review.parse(~s({"verdict": "approve", "ratings": "great"}))
    end
  end

  describe "parse/1 — malformed contents" do
    test "invalid JSON is malformed with the decoder error" do
      assert {:error, {:malformed, {:invalid_json, %Jason.DecodeError{}}}} = Review.parse("not json at all")
    end

    test "valid JSON without a verdict key is malformed" do
      assert {:error, {:malformed, {:missing_verdict, %{"report" => "forgot the verdict"}}}} =
               Review.parse(~s({"report": "forgot the verdict"}))
    end

    test "a JSON scalar (non-object) is malformed" do
      assert {:error, {:malformed, {:missing_verdict, "approve"}}} = Review.parse(~s("approve"))
    end
  end

  describe "read/1 — filesystem layer" do
    setup do
      worktree = Path.join(System.tmp_dir!(), "harness_review_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(worktree)
      on_exit(fn -> File.rm_rf!(worktree) end)
      {:ok, worktree: worktree}
    end

    test "reads and parses an artifact at .harness/review.json", %{worktree: worktree} do
      File.mkdir_p!(Path.join(worktree, ".harness"))

      File.write!(
        Path.join(worktree, Review.artifact_path()),
        ~s({"verdict": "approve", "report": "all green"})
      )

      assert {:ok, %Review{verdict: :approve, report: "all green"}} = Review.read(worktree)
    end

    test "a worktree with no artifact reads as :missing", %{worktree: worktree} do
      assert {:error, :missing} = Review.read(worktree)
    end

    test "an artifact with garbage contents reads as malformed", %{worktree: worktree} do
      File.mkdir_p!(Path.join(worktree, ".harness"))
      File.write!(Path.join(worktree, Review.artifact_path()), "{{{{")

      assert {:error, {:malformed, {:invalid_json, _}}} = Review.read(worktree)
    end
  end

  describe "artifact_path/0" do
    test "is the .harness-scoped path Worktree.commit/2 excludes from staging" do
      assert Review.artifact_path() == ".harness/review.json"
    end
  end
end
