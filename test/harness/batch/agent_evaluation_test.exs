defmodule Harness.Batch.AgentEvaluationTest do
  # async: false because tests reset the singleton AgentRegistry and ProjectRegistry.
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Batch
  alias Harness.Batch.AgentEvaluation
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.Batch.Result
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run.LogRecord
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  @run_timeout_ms 30_000
  @terminal_linger_ms 100

  # GoodAdapter leaves the pass-marker file the reviewer double looks for;
  # SloppyAdapter leaves real work but no marker, so the reviewer rejects it.
  # Under the agent gate, "green vs red" is the REVIEWER's verdict, not a check.
  defmodule GoodAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}) do
      {:ok, {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; echo pass > pass_marker.txt"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule SloppyAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}) do
      {:ok, {"/bin/sh", ["-c", "echo agent-output > agent_output.txt"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule CrashAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}), do: {:ok, {"definitely-not-a-real-binary-xyz", [], []}}

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  setup do
    AgentRegistry.reset()
    ProjectRegistry.reset()
    :ok
  end

  test "compares one task across N adapters with side-by-side metrics" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    item = item("ab-task")
    id = batch_id()

    assert {:ok, %Comparison{batch_id: ^id, task_id: "ab-task", total: 2, entries: entries}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(repo),
               [GoodAdapter, SloppyAdapter],
               eval_opts(base, batch_id: id, result_store: store, max_concurrency: 2)
             )

    assert [%Entry{adapter: GoodAdapter}, %Entry{adapter: SloppyAdapter}] = entries

    assert %Entry{
             adapter: GoodAdapter,
             state: :done,
             reason: :approved,
             verdict: :approve,
             reviewer_diff_size: 0,
             agent_diff_size: diff_size
           } = Enum.at(entries, 0)

    assert is_integer(diff_size) and diff_size > 0
    assert Enum.at(entries, 0).duration_ms >= 0

    assert %Entry{
             adapter: SloppyAdapter,
             state: :failed,
             reason: {:review_rejected, _report},
             verdict: :reject,
             agent_diff_size: red_diff
           } = Enum.at(entries, 1)

    assert is_integer(red_diff) and red_diff > 0
  end

  test "compares real adapter families with per-adapter models instead of the task pin" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    item = %{item("model-ab") | model: "composer-2.5-fast"}
    bin_dir = fake_agent_bin_dir()

    with_path(bin_dir)
    with_agent_models(grok: "grok-4.5")

    assert {:ok, %Comparison{entries: entries}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(repo),
               [Harness.AgentAdapter.Cursor, Grok],
               eval_opts(base,
                 max_concurrency: 2,
                 result_store: false,
                 models: %{"cursor" => "composer-2.5-fast"}
               )
             )

    assert [%Entry{state: :done}, %Entry{state: :done}] = entries

    cursor_run = Enum.at(entries, 0).run_id
    grok_run = Enum.at(entries, 1).run_id

    assert GitFixture.git!(repo, ["show", "harness/#{cursor_run}:agent_model.txt"]) == "composer-2.5-fast"
    assert GitFixture.git!(repo, ["show", "harness/#{grok_run}:agent_model.txt"]) == "grok-4.5"
  end

  test "rejects invalid per-adapter model pairs before spawning" do
    item = %{item("invalid-model") | model: "composer-2.5-fast"}

    assert {:error, {:invalid_model_for_adapter, Grok, "composer-2.5-fast"}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(GitFixture.init_repo()),
               [Grok],
               eval_opts(GitFixture.tmp_base(), result_store: false, models: %{"grok" => "composer-2.5-fast"})
             )
  end

  test "tolerates partial failure without aborting the comparison" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    item = item("partial")

    assert {:ok, %Comparison{entries: entries}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(repo),
               [GoodAdapter, CrashAdapter, SloppyAdapter],
               eval_opts(base, max_concurrency: 3, result_store: false)
             )

    assert length(entries) == 3

    by_adapter = Map.new(entries, &{&1.adapter, &1})
    assert by_adapter[GoodAdapter].state == :done
    assert by_adapter[CrashAdapter].state == :failed
    assert by_adapter[SloppyAdapter].state == :failed
    assert match?({:review_rejected, _}, by_adapter[SloppyAdapter].reason)
  end

  test "run_pinned keeps adapters on their own slots without cross fail-over" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    item = item("pinned")

    assert {:ok, batch} =
             Batch.run_pinned(
               [{item, GoodAdapter}, {item, SloppyAdapter}],
               ProjectFixture.from_repo(repo),
               eval_opts(base, max_concurrency: 2)
             )

    assert length(batch.results) == 2
    assert Enum.at(batch.results, 0).state == :done
    assert Enum.at(batch.results, 1).state == :failed
  end

  test "REGRESSION (Task 68): from_batch/3 raises on adapter/results length mismatch" do
    batch = %Result{
      batch_id: "mismatch-test",
      total: 2,
      max_concurrency: 2,
      results: [
        %Harness.Run.Result{
          run_id: "r1",
          task_id: "t",
          state: :done,
          reason: :approved
        }
      ],
      events: []
    }

    assert_raise ArgumentError, ~r/equal length/, fn ->
      AgentEvaluation.from_batch(batch, [GoodAdapter, SloppyAdapter], false)
    end
  end

  test "from_batch rebuilds a comparison from a persisted batch" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    batch_id = batch_id()
    item = item("reload")

    assert {:ok, batch} =
             Batch.run_pinned(
               [{item, GoodAdapter}, {item, GoodAdapter}],
               ProjectFixture.from_repo(repo),
               eval_opts(base,
                 batch_id: batch_id,
                 result_store: store
               )
             )

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter, GoodAdapter], store)

    assert comparison.batch_id == batch_id
    assert comparison.task_id == "reload"
    assert length(comparison.entries) == 2
    assert Enum.all?(comparison.entries, &(&1.state == :done and &1.verdict == :approve))
  end

  test "from_batch surfaces token usage, preferring the persisted record" do
    store = file_store()
    batch_id = batch_id()

    result =
      %Harness.Run.Result{
        run_id: "run-tok",
        task_id: "t",
        state: :done,
        reason: :approved,
        token_usage: %Harness.TokenUsage{input: 5, output: 1, total: 6}
      }

    record =
      %LogRecord{
        batch_id: batch_id,
        run_id: "run-tok",
        task_id: "t",
        adapter: GoodAdapter,
        state: :done,
        reason: :approved,
        verdict: :approve,
        duration_ms: 10,
        token_usage: %Harness.TokenUsage{input: 500, output: 120, total: 620}
      }

    :ok = Harness.ResultStore.record_run(record, store)

    batch = %Result{
      batch_id: batch_id,
      total: 1,
      max_concurrency: 1,
      results: [result],
      events: []
    }

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter], store)
    [%Entry{token_usage: usage}] = comparison.entries

    # The persisted record's measured usage wins over the live result's.
    assert usage == %Harness.TokenUsage{input: 500, output: 120, total: 620}
  end

  test "from_batch surfaces the reviewer's ratings from the persisted record" do
    store = file_store()
    batch_id = batch_id()

    result = %Harness.Run.Result{run_id: "run-rate", task_id: "t", state: :done, reason: :approved}

    record =
      %LogRecord{
        batch_id: batch_id,
        run_id: "run-rate",
        task_id: "t",
        adapter: GoodAdapter,
        state: :done,
        reason: :approved,
        verdict: :approve,
        duration_ms: 10,
        review_ratings: %{"performance" => 8, "idiom" => 7}
      }

    :ok = Harness.ResultStore.record_run(record, store)

    batch = %Result{batch_id: batch_id, total: 1, max_concurrency: 1, results: [result], events: []}

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter], store)
    [%Entry{ratings: ratings}] = comparison.entries

    assert ratings == %{"performance" => 8, "idiom" => 7}
  end

  test "from_batch surfaces current review_skills scores from the persisted record" do
    store = file_store()
    batch_id = batch_id()

    result = %Harness.Run.Result{run_id: "run-skill-rate", task_id: "t", state: :done, reason: :approved}

    record =
      %LogRecord{
        batch_id: batch_id,
        run_id: "run-skill-rate",
        task_id: "t",
        adapter: GoodAdapter,
        state: :done,
        reason: :approved,
        verdict: :approve,
        duration_ms: 10,
        review_skills: %{
          "otp" => %{"score" => 8, "note" => "clean supervision"},
          "truthfulness" => %{"score" => 7, "note" => "report matched checks"}
        }
      }

    :ok = Harness.ResultStore.record_run(record, store)

    batch = %Result{batch_id: batch_id, total: 1, max_concurrency: 1, results: [result], events: []}

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter], store)
    [%Entry{ratings: ratings}] = comparison.entries

    assert ratings == %{"otp" => 8, "truthfulness" => 7}
  end

  test "from_batch defaults ratings to an empty map when no record is stored" do
    result = %Harness.Run.Result{run_id: "run-norate", task_id: "t", state: :done, reason: :approved}
    batch = %Result{batch_id: "no-store", total: 1, max_concurrency: 1, results: [result], events: []}

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter], false)
    [%Entry{ratings: ratings}] = comparison.entries

    assert ratings == %{}
  end

  test "from_batch falls back to the result's token usage when no record is stored" do
    result =
      %Harness.Run.Result{
        run_id: "run-fallback",
        task_id: "t",
        state: :done,
        reason: :approved,
        token_usage: %Harness.TokenUsage{input: 9, output: 3, total: 12}
      }

    batch = %Result{
      batch_id: "no-store",
      total: 1,
      max_concurrency: 1,
      results: [result],
      events: []
    }

    comparison = AgentEvaluation.from_batch(batch, [GoodAdapter], false)
    [%Entry{token_usage: usage}] = comparison.entries

    assert usage == %Harness.TokenUsage{input: 9, output: 3, total: 12}
  end

  defp eval_opts(base, overrides) do
    Keyword.merge(
      [
        base_dir: base,
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review_verdict_by_file, "pass_marker.txt"}],
        total_timeout: @run_timeout_ms,
        idle_timeout: @run_timeout_ms,
        lifetime_timeout: @run_timeout_ms,
        terminal_linger: @terminal_linger_ms
      ],
      overrides
    )
  end

  defp item(id) do
    %Item{id: id, title: "Task #{id}", prompt: "do task #{id}", agent: :claude}
  end

  defp fake_agent_bin_dir do
    bin_dir = Path.join(System.tmp_dir!(), "harness-agent-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)

    script = Path.join(bin_dir, "agent")

    File.write!(script, """
    #!/bin/sh
    model=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--model" ]; then
        shift
        model="$1"
      fi
      shift
    done
    printf '%s' "$model" > agent_model.txt
    printf 'pass' > pass_marker.txt
    """)

    File.chmod!(script, 0o755)
    File.ln_s!(script, Path.join(bin_dir, "cursor-agent"))
    File.ln_s!(script, Path.join(bin_dir, "grok"))
    bin_dir
  end

  defp with_path(dir) do
    prior = System.get_env("PATH", "")
    System.put_env("PATH", dir <> ":" <> prior)
    on_exit(fn -> System.put_env("PATH", prior) end)
  end

  defp with_agent_models(models) do
    prior = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, models)

    on_exit(fn ->
      if prior do
        Application.put_env(:harness, :agent_model, prior)
      else
        Application.delete_env(:harness, :agent_model)
      end
    end)
  end

  defp batch_id, do: "batch-#{System.unique_integer([:positive])}"

  defp file_store do
    {Harness.ResultStore.Memory,
     root:
       Path.join(
         System.tmp_dir!(),
         "harness-eval-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
       )}
  end
end
