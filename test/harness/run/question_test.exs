defmodule Harness.Run.QuestionTest do
  @moduledoc """
  Unit coverage for `Harness.Run.Question` — mechanical read, identity fence,
  sidecar consumption, and ignore-and-log of unusable artifacts.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Harness.Project
  alias Harness.Roadmap.Item
  alias Harness.Run.Question
  alias Harness.Worktree

  doctest Question

  describe "parse/1" do
    test "reads question, optional context, and derives a stable id" do
      json = ~s({"question": "which API?", "context": "criterion 3", "run_id": "run-1", "invocation": "0"})

      assert {:ok, %Question{question: "which API?", context: "criterion 3", id: "run-1:0"}} = Question.parse(json)
    end

    test "an empty or whitespace question is :empty, not parked" do
      assert {:error, :empty} = Question.parse(~s({"question": "", "run_id": "run-1", "invocation": "0"}))
      assert {:error, :empty} = Question.parse(~s({"question": "   ", "run_id": "run-1", "invocation": "0"}))
    end

    test "malformed JSON and a non-map payload never crash" do
      assert {:error, {:malformed, {:invalid_json, _}}} = Question.parse("{not json")
      assert {:error, {:malformed, {:not_a_map, [1]}}} = Question.parse("[1]")
      assert {:error, {:malformed, :missing_question}} = Question.parse(~s({"run_id": "run-1", "invocation": "0"}))
    end

    test "integer identity fields coerce to strings" do
      assert {:ok, %Question{run_id: "1", invocation: "2", id: "1:2"}} =
               Question.parse(~s({"question": "q", "run_id": 1, "invocation": 2}))
    end
  end

  describe "read/2 — identity fence" do
    setup do
      worktree = tmp_worktree()
      on_exit(fn -> File.rm_rf!(worktree) end)
      {:ok, worktree: worktree, identity: Question.identity("run-1", "0")}
    end

    test "a matching artifact is readable", %{worktree: worktree, identity: identity} do
      write_artifact(worktree, ~s({"question": "which API?", "run_id": "run-1", "invocation": "0"}))

      assert {:ok, %Question{question: "which API?", id: "run-1:0"}} = Question.read(worktree, identity)
    end

    test "a mismatched run_id is stale", %{worktree: worktree, identity: identity} do
      write_artifact(worktree, ~s({"question": "which API?", "run_id": "other", "invocation": "0"}))

      assert {:error, :stale} = Question.read(worktree, identity)
    end

    test "a missing file is :missing", %{worktree: worktree, identity: identity} do
      assert {:error, :missing} = Question.read(worktree, identity)
    end
  end

  describe "take/1 and consume_if_answered/1" do
    setup do
      path = tmp_worktree()
      on_exit(fn -> File.rm_rf!(path) end)
      {:ok, data: data_for(path)}
    end

    test "a fenced question parks once and a leftover file cannot park after consume", %{data: data} do
      write_artifact(
        data.worktree.path,
        ~s({"question": "which API?", "run_id": "run-1", "invocation": "0"})
      )

      assert {:park, taken, %Question{id: "run-1:0"}, true} = Question.take(data)
      parked = Question.park(taken, %Question{id: "run-1:0", run_id: "run-1", invocation: "0", question: "which API?"})

      log =
        capture_log(fn ->
          answered = %{parked | operator_feedback: "use option A"}
          consumed = Question.consume_if_answered(answered)
          assert consumed.pending_question == nil
          assert "run-1:0" in consumed.consumed_question_ids
          assert Question.take(consumed) == :ignore
        end)

      assert log =~ "consumed"
      assert File.exists?(Path.join(data.worktree.path, Question.artifact_path()))
      assert File.exists?(Path.join(data.worktree.path, Question.state_path()))
    end

    test "a sidecar notified flag suppresses a duplicate notify decision", %{data: data} do
      question = %Question{id: "run-1:0", run_id: "run-1", invocation: "0", question: "which API?"}
      write_artifact(data.worktree.path, ~s({"question": "which API?", "run_id": "run-1", "invocation": "0"}))
      Question.park(data, question)

      assert {:park, _taken, %Question{id: "run-1:0"}, false} = Question.take(data)
    end

    test "a different run_id cannot park on another run's file", %{data: data} do
      write_artifact(data.worktree.path, ~s({"question": "which API?", "run_id": "run-1", "invocation": "0"}))

      log =
        capture_log(fn ->
          assert Question.take(%{data | run_id: "run-other"}) == :ignore
        end)

      assert log =~ "stale"
    end

    test "malformed and empty artifacts are ignored and logged, never a crash", %{data: data} do
      File.mkdir_p!(Path.join(data.worktree.path, ".harness"))
      File.write!(Path.join(data.worktree.path, Question.artifact_path()), "{not json")

      log = capture_log(fn -> assert Question.take(data) == :ignore end)
      assert log =~ "malformed"

      write_artifact(data.worktree.path, ~s({"question": "", "run_id": "run-1", "invocation": "0"}))
      log = capture_log(fn -> assert Question.take(data) == :ignore end)
      assert log =~ ":empty"
    end

    test "load_state round-trips pending and consumed across a process-local reread", %{data: data} do
      question = %Question{id: "run-1:0", run_id: "run-1", invocation: "0", question: "which API?"}
      parked = Question.park(data, question)
      parked = Question.record_answer(parked, "use option A")
      consumed = Question.consume_if_answered(%{parked | operator_feedback: "use option A"})

      state = Question.load_state(data.worktree.path)
      assert state.pending == nil
      assert "run-1:0" in state.consumed
      assert consumed.consumed_question_ids == state.consumed
    end
  end

  describe "durable recovery" do
    @tag :tmp_dir
    test "consumed answers survive recovery, while unrelated runs cannot import them", %{tmp_dir: base} do
      source_path = Worktree.run_dir("harness", "run-1", base_dir: base)
      source = data_for(source_path)
      question = %Question{id: "run-1:0", run_id: "run-1", invocation: "0", question: "which API?"}
      parked = Question.park(source, question)
      Question.consume_if_answered(%{parked | operator_feedback: "option A"})
      target = data_for(Path.join(base, "target"))

      target =
        Map.merge(target, %{
          run_id: "run-2",
          base_dir: base,
          dispatch_decision: %{"action" => "resume", "source_run_id" => "run-1"}
        })

      restored = Question.recover(target)
      assert restored.pending_question == question
      assert restored.operator_feedback == "option A"
      assert restored.hold_reason == :question
      assert Question.load_state(target.worktree.path).run_id == "run-2"
      assert Question.recover(%{target | dispatch_decision: %{}}).pending_question == nil

      assert Question.recover(%{target | dispatch_decision: %{"action" => "resume", "source_run_id" => "other"}}).pending_question ==
               nil

      state_path = Path.join(source_path, Question.state_path())
      state = Jason.decode!(File.read!(state_path))
      File.write!(state_path, Jason.encode!(Map.put(state, "run_id", "unrelated")))
      assert Question.recover(target).pending_question == nil
    end

    @tag :tmp_dir
    test "a failed sidecar write is visible instead of claiming persistence", %{tmp_dir: path} do
      File.write!(Path.join(path, ".harness"), "not a directory")
      question = %Question{id: "run-1:0", run_id: "run-1", invocation: "0", question: "which API?"}
      assert_raise File.Error, fn -> Question.park(data_for(path), question) end
    end
  end

  describe "answer_prompt/2" do
    test "threads question and answer verbatim with no interpretation" do
      question = %Question{
        id: "run-1:0",
        run_id: "run-1",
        invocation: "0",
        question: "use GenServer or gen_statem?",
        context: "criterion 2"
      }

      prompt = Question.answer_prompt(question, "gen_statem")
      assert prompt =~ "use GenServer or gen_statem?"
      assert prompt =~ "criterion 2"
      assert prompt =~ "gen_statem"
    end
  end

  @spec tmp_worktree() :: String.t()
  defp tmp_worktree do
    path = Path.join(System.tmp_dir!(), "harness_question_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  @spec write_artifact(String.t(), String.t()) :: :ok
  defp write_artifact(worktree, contents) do
    File.mkdir_p!(Path.join(worktree, ".harness"))
    File.write!(Path.join(worktree, Question.artifact_path()), contents)
  end

  @spec data_for(String.t()) :: map()
  defp data_for(path) do
    %{
      run_id: "run-1",
      implementer_attempt: 0,
      consumed_question_ids: [],
      pending_question: nil,
      operator_feedback: nil,
      hold_reason: nil,
      land_attempt: 1,
      item: %Item{id: "8", title: "q", prompt: "do", agent: :claude},
      project: %Project{name: "harness", source: {:local, path}, roadmap_path: path, languages: [:elixir]},
      worktree: %Worktree{id: "run-1", path: path, branch: "harness/run-1", repo: path, base_sha: "abc"}
    }
  end
end
