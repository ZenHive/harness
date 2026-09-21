defmodule Harness.Insights.ProjectEvidenceTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Insights
  alias Harness.Insights.Evidence
  alias Harness.Insights.ProjectEvidence
  alias Harness.Insights.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Test.InsightsScriptedWitness
  alias Harness.Test.InsightsWitness

  setup do
    keys = [:insights_witness, :insights_script, :agent_model, :result_store]
    old = Map.new(keys, &{&1, Application.get_env(:harness, &1)})
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    Application.put_env(:harness, :result_store, nil)
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    Store.get("settings")
    :ets.delete_all_objects(Store)
    ProjectRegistry.reset()
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo, name: "inline")
    ProjectRegistry.register(project)

    commit(repo, %{
      "roadmap/tasks.toml" =>
        ~s([[task]]\nid = "427"\nstatus = "done"\nbody = "docs/verification/repair.json docs/verification/missing.json"\n),
      "CLAUDE.md" => "Focused dispatch checks; full QA after merge. Reviewer fix-and-approve is intentional.",
      "AGENTS.md" => "Use canonical workflow decisions.",
      "priv/includes/harness-workflow.md" => "No numeric reviewer rewrite threshold.",
      "docs/verification/repair.json" => "Repair tests passed; live activation remains unverified."
    })

    :ok = Insights.configure(Map.put(Insights.settings(), "enabled", true))

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if is_nil(value), do: Application.delete_env(:harness, key), else: Application.put_env(:harness, key, value)
      end)

      :ets.delete_all_objects(Store)
      ProjectRegistry.reset()
    end)

    %{repo: repo, project: project}
  end

  test "inline commit and changed intent revisit exact finding without mutating a run", %{repo: repo} do
    prior = %{
      "id" => "rejected-427",
      "title" => "Rejected run",
      "facts" => "Historical reviewer rejected delivery",
      "projects" => ["inline"],
      "runs" => ["old-run"]
    }

    Store.put_many([{"finding/rejected-427", "finding", prior}, {"revision/old", "revision/rejected-427", prior}])
    owner = self()

    Application.put_env(:harness, :insights_script, fn context, _ ->
      send(owner, {:context, context})
      source = Enum.find(context["sources"], &(&1["path"] == "docs/verification/repair.json"))

      finding =
        source
        |> InsightsWitness.finding("rejected-427")
        |> Map.put("assessment", "Repair tested; live activation still unverified")

      {:ok, %{"findings" => [finding]}}
    end)

    assert :ok = Insights.observe("inline-first")
    assert_received {:context, first}
    assert prior in first["previous_findings"]
    assert Insights.status()["last_pass"]["changed_runs"] == 0
    assert Insights.status()["last_pass"]["partial"]
    [historical, repaired] = Insights.history("rejected-427")["revisions"]
    assert historical == prior
    assert repaired["runs"] == ["old-run"]
    assert repaired["assessment"] =~ "unverified"
    [citation] = repaired["citations"]
    assert citation["revision"] == String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))
    assert citation["provenance"] =~ "referenced by roadmap"
    assert :ok = Insights.observe("unchanged")
    refute_received {:context, _}
    commit(repo, %{"docs/verification/repair.json" => "Additional regression passed; activation unverified."})
    assert :ok = Insights.observe("repair-only")
    assert_received {:context, repair}
    assert Enum.any?(repair["sources"], &(&1["text"] =~ "Additional regression"))

    commit(repo, %{
      "roadmap/tasks.toml" =>
        ~s([[task]]\nid = "427"\nbody = "Do not restore a rollout QA gate. docs/verification/repair.json"\n)
    })

    assert :ok = Insights.observe("decision-only")
    assert_received {:context, decision}
    assert Enum.any?(decision["sources"], &(&1["text"] =~ "Do not restore"))
    assert Enum.count_until(Insights.history("rejected-427")["revisions"], 5) == 4
  end

  test "pinned snapshots ignore working files and reject unreferenced paths and symlinks", %{repo: repo, project: project} do
    File.write!(Path.join(repo, "docs/verification/repair.json"), "uncommitted replacement")
    sources = ProjectEvidence.sources(project)
    repair = Enum.find(sources, &(&1["path"] == "docs/verification/repair.json"))
    assert repair["content"] =~ "Repair tests passed"
    File.ln_s!("../../CLAUDE.md", Path.join(repo, "docs/verification/link.json"))
    commit(repo, %{"roadmap/tasks.toml" => "docs/verification/link.json docs/verification/../../secret.json"})
    sources = ProjectEvidence.sources(project)
    refute Enum.any?(sources, &String.contains?(&1["field"], "secret"))
    link = Enum.find(sources, &(&1["path"] == "docs/verification/link.json"))
    assert link["availability"] == "unavailable"
    assert link["content"] == ""
    assert repair["content"] =~ "Repair tests passed"
  end

  test "catalog, task lookup and continuations retain attribution and report unavailable evidence", %{repo: repo} do
    commit(repo, %{"docs/verification/repair.json" => String.duplicate("界", 4000) <> "TAIL"})
    {:ok, batch} = Evidence.batch(%{})
    roadmap = Enum.find(batch.snapshots, &(&1["authority"] == "current_intent"))
    assert {:ok, task} = Evidence.task(batch, roadmap["source_id"], 427)
    assert task["text"] =~ "status = \"done\""
    assert {:error, :unknown_task} = Evidence.task(batch, roadmap["source_id"], 999)
    repair = Enum.find(batch.snapshots, &(&1["path"] == "docs/verification/repair.json"))
    assert repair["availability"] == "truncated"
    commit(repo, %{"docs/verification/repair.json" => "later replacement"})
    assert {:ok, tail} = Evidence.read(batch, repair["source_id"], repair["next_offset"])
    assert tail["text"] =~ "TAIL"
    assert tail["revision"] == repair["revision"]
    missing = Enum.find(batch.snapshots, &(&1["path"] == "docs/verification/missing.json"))
    assert {:ok, unavailable} = Evidence.read(batch, missing["source_id"], 0)
    assert unavailable["availability"] == "unavailable"
    assert {:error, :unknown_source_or_offset} = Evidence.read(batch, "/etc/passwd", 0)
    assert Evidence.catalog(batch, 0)["source_catalog"] != []
    assert Evidence.catalog(batch, 100)["catalog_next_offset"] == nil
  end

  test "catalog retrieval finishes before checkpointing and an unrelated commit stays cheap", %{repo: repo} do
    paths = for n <- 1..25, do: "docs/verification/report-#{String.pad_leading(to_string(n), 2, "0")}.json"
    files = Map.new(paths, &{&1, "Observed regression evidence " <> &1})
    commit(repo, Map.put(files, "roadmap/tasks.toml", Enum.join(paths, "\n")))
    owner = self()

    Application.put_env(:harness, :insights_script, fn context, _ ->
      assert Store.get("seen/project/inline") == nil
      assert Store.get("progress") == nil
      assert context["reads_remaining"] == 32 - length(context["retrieval_history"])
      send(owner, :retrieved)
      source = Enum.find(context["source_catalog"], &(&1["path"] == List.last(paths)))

      cond do
        context["read_result"] -> {:ok, %{"findings" => [InsightsWitness.finding(context["read_result"])]}}
        source -> {:ok, %{"read" => %{"kind" => "source", "source_id" => source["source_id"], "offset" => 0}}}
        true -> {:ok, %{"read" => %{"kind" => "catalog", "offset" => context["catalog_next_offset"]}}}
      end
    end)

    assert :ok = Insights.observe("catalog-retrieval")
    assert_received :retrieved
    assert_received :retrieved
    assert_received :retrieved
    refute_received :retrieved
    [finding] = Insights.findings()["items"]
    assert hd(finding["citations"])["excerpt"] =~ List.last(paths)
    commit(repo, %{"README.md" => "An unrelated commit"})
    assert :ok = Insights.observe("unrelated-commit")
    refute_received :retrieved
  end

  test "reference and blob bounds stay explicit", %{repo: repo, project: project} do
    paths = for n <- 1..65, do: "docs/verification/missing-#{n}.json"
    paths = ["docs/verification/aaa-large.json", "docs/verification/aab-invalid.json" | paths]

    commit(repo, %{
      "roadmap/tasks.toml" => Enum.join(paths, "\n"),
      "docs/verification/aaa-large.json" => String.duplicate("x", 2_000_001),
      "docs/verification/aab-invalid.json" => <<255>>
    })

    sources = ProjectEvidence.sources(project)
    repairs = Enum.filter(sources, &(&1["authority"] == "repair_evidence"))
    assert Enum.count_until(repairs, 65) == 64
    assert Enum.all?(repairs, &(&1["availability"] == "unavailable"))
    catalog = Enum.find(sources, &(&1["field"] == "reference_catalog"))
    assert catalog["availability"] == "truncated"
    assert Enum.count_until(Jason.decode!(catalog["content"])["paths"], 68) == 67
  end

  test "roadmap and code repositories retain independent revision attribution", %{project: project} do
    roadmap_repo = GitFixture.init_repo()
    commit(roadmap_repo, %{"roadmap/tasks.toml" => "docs/verification/repair.json"})
    sources = ProjectEvidence.sources(%{project | roadmap_path: roadmap_repo})
    roadmap = Enum.find(sources, &(&1["authority"] == "current_intent"))
    repair = Enum.find(sources, &(&1["path"] == "docs/verification/repair.json"))
    assert roadmap["revision"] == String.trim(GitFixture.git!(roadmap_repo, ["rev-parse", "HEAD"]))
    refute roadmap["revision"] == repair["revision"]
    assert repair["provenance"] =~ roadmap["revision"]
    assert repair["text"] =~ "Repair tests passed"
  end

  @tag :integration
  @tag timeout: 240_000
  test "live observer reconciles historical rejection claims using committed repair reports" do
    assert System.find_executable("codex"), "Install Codex and authenticate with codex login."
    Application.delete_env(:harness, :insights_witness)
    ProjectRegistry.reset()
    project = ProjectFixture.from_repo(File.cwd!(), name: "harness")
    ProjectRegistry.register(project)

    claims = [
      {"1c2094d1-929f-4c5d-a61f-3001de87971c", "326", "The rejected 326 run leaves the EPIPE diagnosis unresolved."},
      {"a4cb28ea-af09-4043-a329-014b03ed75bb", "448",
       "The rejected 448 run requires green full QA before workflow rollout."},
      {"7f961142-3b55-4eb3-bf4c-211c73ee4b6f", "427", "The stalled 427 run has no later repair verification."}
    ]

    for {id, task, claim} <- claims do
      prior = %{
        "id" => id,
        "title" => "Historical task " <> task,
        "facts" => claim,
        "projects" => ["harness"],
        "runs" => [],
        "citations" => [],
        "provenance" => "Reproduction fixture of historical claims reported in Task 451; not a production finding export"
      }

      Store.put_many([{"finding/" <> id, "finding", prior}, {"revision/fixture-" <> id, "revision/" <> id, prior}])
    end

    assert :ok = Insights.observe("live-inline-reconciliation")
    pass = Store.get("pass/live-inline-reconciliation")
    findings = Insights.findings("harness")["items"]
    reconciled = Enum.filter(findings, &(&1["pass_id"] == "live-inline-reconciliation"))

    for {id, _, _} <- claims do
      assert Enum.any?(reconciled, &(&1["id"] == id)), "Live observer did not reconcile exact finding #{id}"
      assert Enum.count_until(Insights.history(id)["revisions"], 3) == 2
    end

    for finding <- reconciled, citation <- finding["citations"] do
      source = Enum.find(pass["sources"], &(&1["source_id"] == citation["source_id"]))
      assert source
      assert String.contains?(source["text"], citation["excerpt"])
      assert citation["revision"]
    end

    assert Enum.any?(reconciled, fn finding ->
             Enum.any?(finding["citations"], &(&1["authority"] == "repair_evidence"))
           end)

    File.mkdir_p!(".harness")

    File.write!(
      ".harness/task-451-live.json",
      Jason.encode!(
        %{
          pass: pass,
          findings: reconciled,
          fixture: "Historical claims from Task 451, committed repository evidence, real Codex observer"
        },
        pretty: true
      )
    )
  end

  defp commit(repo, files) do
    Enum.each(files, fn {path, text} ->
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), text)
    end)

    paths =
      Map.keys(files) ++
        if(File.exists?(Path.join(repo, "docs/verification/link.json")), do: ["docs/verification/link.json"], else: [])

    GitFixture.git!(repo, ["add", "--" | paths])
    GitFixture.git!(repo, ["commit", "-qm", "evidence fixture"])
  end
end
