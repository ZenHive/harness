defmodule Harness.Run.QuestionChannelTest do
  @moduledoc """
  Run-lifecycle coverage for the implementer question channel: park at the
  invocation boundary, FileSink witness, steer+resume injection, timeout
  policy, stale-file consumption, and sidecar survival across a process crash.
  """

  use Harness.RunCase, async: false

  alias Harness.Notification.Event
  alias Harness.Notification.FileSink
  alias Harness.Run.Question
  alias Harness.Test.QuestionAdapter

  setup do
    prior_sinks = Application.get_env(:harness, :notification_sinks)
    prior_file = Application.get_env(:harness, FileSink)

    on_exit(fn ->
      restore_env(:notification_sinks, prior_sinks)
      restore_file_sink(prior_file)
      Application.delete_env(:harness, :test_capture_pid)
    end)

    :ok
  end

  describe "park at the implementer-invocation boundary" do
    @tag :tmp_dir
    test "a fenced question.json parks in :held and appends a FileSink JSONL line", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settled.jsonl")
      Application.put_env(:harness, FileSink, path: path)
      Application.put_env(:harness, :notification_sinks, [FileSink])

      {run_id, _pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      await_held(run_id)

      assert {:ok, %Status{state: :held, held?: true, hold_reason: :question}} = Run.status(run_id)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      decoded = Enum.map(lines, &Jason.decode!/1)
      question_line = Enum.find(decoded, &(&1["type"] == "question"))
      assert question_line["run_id"] == run_id
      assert question_line["outcome"]["question"] == "which API shape?"
      assert question_line["summary"] =~ "which API shape?"
    end

    test "malformed, empty, and stale-identity artifacts proceed to commit/review" do
      for command <- [:malformed, :empty, :stale_identity] do
        {run_id, pid} =
          start(
            adapter: QuestionAdapter,
            adapter_opts: [command: command],
            lifetime_timeout: 30_000,
            terminal_linger: 100
          )

        assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      end
    end
  end

  describe "steer + resume" do
    test "question and answer both reach the re-invoked agent's prompt" do
      {run_id, pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      await_held(run_id)
      assert {:error, :answer_required} = Run.resume(run_id)
      assert :ok = Run.steer(run_id, "use the existing GenServer")
      assert :ok = Run.resume(run_id)

      assert %Result{state: :done, reason: :approved, composed_inputs: inputs} = await_result(run_id, pid)

      resume = Enum.find(inputs, &(&1.session == :resume))
      assert resume.prompt =~ "which API shape?"
      assert resume.prompt =~ "optional context"
      assert resume.prompt =~ "use the existing GenServer"
    end

    test "a leftover question.json cannot park the next invocation; a new identity can" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {run_id, pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question_twice, counter: counter],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      await_held(run_id)
      assert :ok = Run.steer(run_id, "answer one")
      assert :ok = Run.resume(run_id)

      await_held(run_id)
      assert {:ok, %Status{hold_reason: :question}} = Run.status(run_id)
      assert :ok = Run.steer(run_id, "answer two")
      assert :ok = Run.resume(run_id)

      assert %Result{state: :done, reason: :approved, composed_inputs: inputs} = await_result(run_id, pid)

      [first_resume, second_resume] = Enum.filter(inputs, &(&1.session == :resume))
      assert first_resume.prompt =~ "first question"
      assert first_resume.prompt =~ "answer one"
      assert second_resume.prompt =~ "second question"
      assert second_resume.prompt =~ "answer two"
      refute second_resume.prompt =~ "first question"
    end
  end

  describe "timeout policy" do
    test "question-held time counts against the existing lifetime budget" do
      {run_id, pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question],
          lifetime_timeout: 1_000,
          terminal_linger: 100
        )

      await_held(run_id)
      result = await_result(run_id, pid, 5_000)
      assert %Result{state: :failed, reason: :timed_out} = result
      assert Worktree.retained?(result.worktree_path)
    end

    test "resume after a question hold does not re-arm a fresh lifetime budget" do
      {run_id, pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question_then_sleep],
          lifetime_timeout: 3_000,
          terminal_linger: 100
        )

      await_held(run_id)
      Process.sleep(2_000)
      assert {:ok, %Status{state: :held, hold_reason: :question}} = Run.status(run_id)

      assert :ok = Run.steer(run_id, "go")
      started = System.monotonic_time(:millisecond)
      assert :ok = Run.resume(run_id)
      result = await_result(run_id, pid, 8_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert %Result{state: :failed, reason: :timed_out} = result
      assert elapsed < 1_800
    end
  end

  describe "process recovery" do
    test "sidecar pending state survives a gen_statem crash without a second notify" do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      {run_id, pid} =
        start(
          adapter: QuestionAdapter,
          adapter_opts: [command: :question],
          lifetime_timeout: 30_000,
          terminal_linger: 100
        )

      await_held(run_id)
      assert_receive {:notify, %Event{type: :question, run_id: ^run_id, outcome: %{question: "which API shape?"}}}, 2_000

      {:ok, %Status{worktree_path: path}} = Run.status(run_id)
      state_before = Question.load_state(path)
      assert state_before.pending["id"] == "#{run_id}:0"
      assert state_before.pending["notified"] == true

      undef = {:undef, [{Harness.Run, :held, [:info, {:transcript_chunk, "x"}, %{}]}]}
      assert :ok = :gen_statem.stop(pid, undef, 5_000)
      result = await_result(run_id, pid)
      assert %Result{state: :failed, reason: {:run_crashed, _}} = result

      state_after = Question.load_state(result.worktree_path)
      assert state_after.pending["question"] == "which API shape?"
      assert state_after.pending["notified"] == true
      refute_receive {:notify, %Event{type: :question}}, 200

      data = %{
        run_id: run_id,
        implementer_attempt: 0,
        consumed_question_ids: [],
        pending_question: nil,
        worktree: %Worktree{
          id: run_id,
          path: result.worktree_path,
          branch: "harness/#{run_id}",
          repo: result.worktree_path,
          base_sha: "abc"
        }
      }

      assert {:park, _taken, %Question{}, false} = Question.take(data)
    end
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)

  @spec restore_file_sink(term()) :: :ok
  defp restore_file_sink(nil), do: Application.delete_env(:harness, FileSink)
  defp restore_file_sink(value), do: Application.put_env(:harness, FileSink, value)
end
