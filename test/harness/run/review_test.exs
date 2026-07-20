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

  describe "parse/1 — coalesced task outcomes" do
    test "preserves each member outcome from a coalesced review" do
      json = ~s({"verdict": "approve", "task_outcomes": {"41": "approved", "42": "approved"}})

      assert {:ok, %Review{task_outcomes: %{"41" => "approved", "42" => "approved"}}} = Review.parse(json)
    end
  end

  describe "parse/1 — facets (the routing KEY)" do
    test "the facets block rides through verbatim as a free-form string-keyed map" do
      json =
        ~s({"verdict": "approve", "report": "ok", "facets": ) <>
          ~s({"language": "elixir", "surface": "otp", "archetype": "feature", "difficulty": "hard", "risk": "low"}})

      assert {:ok, %Review{facets: facets}} = Review.parse(json)

      assert facets == %{
               "language" => "elixir",
               "surface" => "otp",
               "archetype" => "feature",
               "difficulty" => "hard",
               "risk" => "low"
             }
    end

    test "facets is open-vocabulary — unknown keys are preserved, never validated against an enum" do
      json = ~s({"verdict": "approve", "facets": {"novel_axis": "whatever", "language": "rust"}})

      assert {:ok, %Review{facets: %{"novel_axis" => "whatever", "language" => "rust"}}} = Review.parse(json)
    end

    test "a missing or non-map facets block defaults to an empty map" do
      assert {:ok, %Review{facets: %{}}} = Review.parse(~s({"verdict": "approve"}))
      assert {:ok, %Review{facets: %{}}} = Review.parse(~s({"verdict": "reject", "facets": "n/a"}))
    end
  end

  describe "parse/1 — skills (the routing VALUE)" do
    test "the two-axis skills rubric rides through verbatim with nested score/note maps" do
      json =
        ~s({"verdict": "approve", "report": "ok", "skills": ) <>
          ~s({"otp": {"score": 8, "note": "clean gen_statem"}, "truthfulness": {"score": 9, "note": "report matched diff"}}})

      assert {:ok, %Review{skills: skills}} = Review.parse(json)

      assert skills == %{
               "otp" => %{"score" => 8, "note" => "clean gen_statem"},
               "truthfulness" => %{"score" => 9, "note" => "report matched diff"}
             }
    end

    test "a missing or non-map skills block defaults to an empty map" do
      assert {:ok, %Review{skills: %{}}} = Review.parse(~s({"verdict": "approve"}))
      assert {:ok, %Review{skills: %{}}} = Review.parse(~s({"verdict": "reject", "skills": 7}))
    end

    test "legacy ratings and the new skills block coexist for back-compat" do
      json =
        ~s({"verdict": "approve", "ratings": {"performance": 8}, ) <>
          ~s("skills": {"ecto": {"score": 7, "note": "migration"}}})

      assert {:ok, %Review{ratings: %{"performance" => 8}, skills: %{"ecto" => %{"score" => 7, "note" => "migration"}}}} =
               Review.parse(json)
    end
  end

  describe "parse/1 — checks and concerns" do
    test "checks ride through verbatim as the reviewer's structured command claims" do
      json =
        ~s({"verdict": "approve", "report": "ok", "checks": ) <>
          ~s({"mix precommit": {"passed": true, "output": "green"}, "mix test.json": {"passed": false, "output": "doctest doc chunk"}}})

      assert {:ok, %Review{checks: checks}} = Review.parse(json)

      assert checks == %{
               "mix precommit" => %{"passed" => true, "output" => "green"},
               "mix test.json" => %{"passed" => false, "output" => "doctest doc chunk"}
             }
    end

    test "concerns ride through verbatim as a list of self-flagged caveats" do
      json =
        ~s({"verdict": "approve", "report": "ok", "concerns": ) <>
          ~s([{"kind": "dismissed_red", "mechanism": "reproduced doc chunk config bug", "check": "mix precommit"}]})

      assert {:ok, %Review{concerns: concerns}} = Review.parse(json)

      assert concerns == [
               %{
                 "kind" => "dismissed_red",
                 "mechanism" => "reproduced doc chunk config bug",
                 "check" => "mix precommit"
               }
             ]
    end

    test "missing or wrong-shaped checks and concerns default without crashing" do
      assert {:ok, %Review{checks: %{}, concerns: []}} = Review.parse(~s({"verdict": "approve"}))

      assert {:ok, %Review{checks: %{}, concerns: []}} =
               Review.parse(~s({"verdict": "approve", "checks": "none", "concerns": {"note": "bad shape"}}))
    end
  end

  describe "parse/1 — proposed_tasks" do
    test "preserves structured discovery proposals for the orchestrator" do
      json =
        ~s({"verdict": "approve", "proposed_tasks": [{"title": "Add observer", "body": "Capture events.", ) <>
          ~s("suggested_scores": {"difficulty": 3, "benefit": 8}, "suggested_markers": ["parallel"], ) <>
          ~s("evidence": "Reviewer found an unobservable failure path."}]})

      assert {:ok, %Review{proposed_tasks: [proposal]}} = Review.parse(json)

      assert proposal == %{
               "title" => "Add observer",
               "body" => "Capture events.",
               "suggested_scores" => %{"difficulty" => 3, "benefit" => 8},
               "suggested_markers" => ["parallel"],
               "evidence" => "Reviewer found an unobservable failure path."
             }
    end

    test "missing or wrong-shaped proposed_tasks defaults to an empty list" do
      assert {:ok, %Review{proposed_tasks: []}} = Review.parse(~s({"verdict": "approve"}))
      assert {:ok, %Review{proposed_tasks: []}} = Review.parse(~s({"verdict": "approve", "proposed_tasks": {}}))
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
