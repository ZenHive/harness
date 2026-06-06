defmodule Harness.CapabilityScoreTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.CapabilityScore
  alias Harness.CapabilityScore.Assessment
  alias Harness.CapabilityScore.Entry
  alias Harness.Config
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "harness_capability_score_test_#{System.unique_integer([:positive])}"
      )

    assessment_root = Path.join(root, "assessment")
    File.mkdir_p!(assessment_root)

    on_exit(fn ->
      MemoryStore.reset(root: root)
      File.rm_rf(root)
    end)

    {:ok, store: {MemoryStore, root: root}, assessment_root: assessment_root}
  end

  test "group_by_facet buckets records by normalized review_facets" do
    records = [
      record(review_facets: %{"surface" => "otp", "language" => "elixir"}),
      record(review_facets: %{"language" => "elixir", "surface" => "otp"}),
      record(review_facets: %{"surface" => "liveview"}),
      record(review_facets: %{})
    ]

    grouped = CapabilityScore.group_by_facet(records)

    assert map_size(grouped) == 3
    assert length(Map.get(grouped, facet_key(%{"language" => "elixir", "surface" => "otp"}))) == 2
    assert length(Map.get(grouped, facet_key(%{"surface" => "liveview"}))) == 1
    assert length(Map.get(grouped, facet_key(%{}))) == 1
  end

  test "facet_facts rolls per-agent KPI facts without weighting" do
    records = [
      record(agent: :codex, verdict: :approve, review_iterations: 0, token_usage: tokens(100, 20)),
      record(agent: :codex, verdict: :reject, review_iterations: 1),
      record(agent: :claude, verdict: :approve, review_iterations: 0, token_usage: tokens(50, 10))
    ]

    facts = CapabilityScore.facet_facts(records)

    assert facts[:codex].run_count == 2
    assert facts[:codex].success_rate == 0.5
    assert facts[:claude].success_rate == 1.0
    assert facts[:claude].cost_to_green == 60.0
  end

  test "read_assessment returns :no_data when the artifact is absent", %{assessment_root: root} do
    assert :no_data = CapabilityScore.read_assessment(assessment_root: root)
  end

  test "save_assessment and read_assessment round-trip the artifact", %{assessment_root: root} do
    assessment = sample_assessment()

    assert :ok = CapabilityScore.save_assessment(assessment, assessment_root: root)
    assert {:ok, loaded} = CapabilityScore.read_assessment(assessment_root: root)
    assert loaded.assessed_at == assessment.assessed_at
    assert loaded.record_count == assessment.record_count
    assert [%Entry{winner: :codex, reasoning: "best at otp"}] = loaded.entries
  end

  test "recommend exploits the scout winner when facets match the assessment", %{assessment_root: root} do
    assert :ok =
             CapabilityScore.save_assessment(
               %Assessment{
                 assessed_at: ~U[2026-06-06 12:00:00Z],
                 record_count: 2,
                 entries: [
                   %Entry{
                     facet: %{"surface" => "otp", "language" => "elixir"},
                     winner: :codex,
                     reasoning: "Codex wins otp feature work on approve + cost.",
                     by_agent: %{}
                   }
                 ]
               },
               assessment_root: root
             )

    assert {:ok, recommendation} =
             CapabilityScore.recommend(
               %{"surface" => "otp", "language" => "elixir"},
               agents: [:claude, :codex],
               assessment_root: root
             )

    assert recommendation.agent == :codex
    assert recommendation.strategy == :exploit
    assert recommendation.scout_reasoning =~ "Codex wins"
    assert recommendation.matched_facet == %{"language" => "elixir", "surface" => "otp"}
  end

  test "recommend explores when the facet is unmeasured", %{assessment_root: root} do
    assert :ok =
             CapabilityScore.save_assessment(
               %Assessment{
                 assessed_at: ~U[2026-06-06 12:00:00Z],
                 record_count: 1,
                 entries: [
                   %Entry{
                     facet: %{"surface" => "otp"},
                     winner: :codex,
                     reasoning: "otp only",
                     by_agent: %{}
                   }
                 ]
               },
               assessment_root: root
             )

    assert {:ok, recommendation} =
             CapabilityScore.recommend(
               %{"surface" => "liveview"},
               agents: [:claude, :codex, :cursor],
               fallback_agent: :cursor,
               assessment_root: root
             )

    assert recommendation.agent == :cursor
    assert recommendation.strategy == :explore
    assert recommendation.rationale == :unmeasured_facet
  end

  test "recommend falls back when no assessment exists", %{assessment_root: root} do
    configured = Config.get({:dispatch, :default_agent})

    assert {:ok, recommendation} =
             CapabilityScore.recommend(%{"surface" => "otp"},
               agents: [:claude, :codex],
               assessment_root: root
             )

    assert recommendation.strategy == :fallback_no_data
    assert recommendation.agent == configured
    assert recommendation.rationale == :no_assessment
  end

  test "artifact_rel_path points at the scout artifact inside a worktree" do
    assert CapabilityScore.artifact_rel_path() == ".harness/facet-assessment.json"
  end

  test "assessment_path expands assessment_root to the facet artifact file" do
    root = Path.join(System.tmp_dir!(), "assessment-root-#{System.unique_integer([:positive])}")

    assert String.ends_with?(CapabilityScore.assessment_path(assessment_root: root), "facet-assessment.json")
  end

  test "recommend propagates assessment read errors" do
    dir = Path.join(System.tmp_dir!(), "assessment-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, _} = CapabilityScore.recommend(%{"surface" => "otp"}, assessment_path: dir)
  end

  test "facets_from_domain maps a domain tag to a surface facet" do
    assert CapabilityScore.facets_from_domain(:otp) == %{"surface" => "otp"}
  end

  test "recommend matches on partial facet overlap when keys agree" do
    assessment = %Assessment{
      assessed_at: ~U[2026-06-06 12:00:00Z],
      record_count: 1,
      entries: [
        %Entry{
          facet: %{"surface" => "otp", "language" => "elixir"},
          winner: :claude,
          reasoning: "claude on otp elixir",
          by_agent: %{}
        }
      ]
    }

    root = Path.join(System.tmp_dir!(), "facet-partial-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    assert :ok = CapabilityScore.save_assessment(assessment, assessment_root: root)

    assert {:ok, %{agent: :claude}} =
             CapabilityScore.recommend(%{"surface" => "otp"},
               agents: [:claude, :codex],
               assessment_root: root
             )
  end

  test "build_scout_context groups facet facts for the scout prompt" do
    records = [
      record(review_facets: %{"surface" => "otp"}, agent: :codex, verdict: :approve)
    ]

    assert [%{facet: %{"surface" => "otp"}, by_agent: %{codex: %{run_count: 1}}}] =
             CapabilityScore.build_scout_context(records)
  end

  test "read_assessment returns error on invalid JSON" do
    dir = Path.join(System.tmp_dir!(), "invalid-json-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)
    path = Path.join(dir, "facet-assessment.json")
    File.write!(path, "not-json")

    assert {:error, {:invalid_json, _}} = CapabilityScore.read_assessment(assessment_path: path)
  end

  test "decode_assessment rejects malformed JSON payloads" do
    dir = Path.join(System.tmp_dir!(), "bad-assessment-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)
    path = Path.join(dir, "facet-assessment.json")
    File.write!(path, ~s({"entries": "not-a-list"}))

    assert {:error, {:malformed_assessment, _}} = CapabilityScore.read_assessment(assessment_path: path)
  end

  test "refresh injects grouped facts into the saved assessment", %{store: store, assessment_root: root} do
    assert :ok =
             ResultStore.record_run(
               record(
                 review_facets: %{"surface" => "otp"},
                 agent: :codex,
                 verdict: :approve
               ),
               store
             )

    scout = fn context ->
      assert [%{facet: %{"surface" => "otp"}, by_agent: by_agent}] = context.groups
      assert by_agent[:codex].run_count == 1

      {:ok,
       %Assessment{
         assessed_at: ~U[2026-06-06 12:00:00Z],
         record_count: context.record_count,
         entries: [
           %Entry{
             facet: %{"surface" => "otp"},
             winner: :codex,
             reasoning: "only agent measured",
             by_agent: %{}
           }
         ]
       }}
    end

    prev = Application.get_env(:harness, :capability_scout)
    on_exit(fn -> restore_scout(prev) end)
    Application.put_env(:harness, :capability_scout, scout)

    assert {:ok, assessment} =
             CapabilityScore.refresh(result_store: store, assessment_root: root)

    assert assessment.record_count == 1
    assert assessment.entries |> hd() |> Map.fetch!(:by_agent) |> Map.has_key?(:codex)
    assert {:ok, loaded} = CapabilityScore.read_assessment(assessment_root: root)
    assert loaded.entries |> hd() |> Map.fetch!(:by_agent) |> Map.has_key?(:codex)
  end

  defp sample_assessment do
    %Assessment{
      assessed_at: ~U[2026-06-06 12:00:00Z],
      record_count: 1,
      entries: [
        %Entry{
          facet: %{"surface" => "otp"},
          winner: :codex,
          reasoning: "best at otp",
          by_agent: %{codex: %{run_count: 1}}
        }
      ]
    }
  end

  defp record(opts) do
    %LogRecord{
      batch_id: "batch-1",
      run_id: Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}"),
      task_id: "task-1",
      adapter: Keyword.get(opts, :adapter, Claude),
      state: Keyword.get(opts, :state, :done),
      reason: Keyword.get(opts, :reason, :approved),
      duration_ms: 100,
      agent: Keyword.get(opts, :agent, :claude),
      verdict: Keyword.get(opts, :verdict, :approve),
      review_iterations: Keyword.get(opts, :review_iterations, 0),
      review_facets: Keyword.get(opts, :review_facets, %{}),
      token_usage: Keyword.get(opts, :token_usage, TokenUsage.empty())
    }
  end

  defp tokens(input, output), do: %TokenUsage{input: input, output: output, total: input + output}

  defp facet_key(facet),
    do: facet |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort() |> Map.new() |> Jason.encode!()

  defp restore_scout(nil), do: Application.delete_env(:harness, :capability_scout)
  defp restore_scout(value), do: Application.put_env(:harness, :capability_scout, value)
end
