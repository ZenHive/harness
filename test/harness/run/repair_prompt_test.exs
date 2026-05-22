defmodule Harness.Run.RepairPromptTest do
  use ExUnit.Case, async: true

  alias Harness.Roadmap.Item
  alias Harness.Run.RepairPrompt
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  describe "build/4" do
    test "renders only the failed checks, never the passed ones" do
      verdict =
        verdict([
          result(name: "credo", status: :pass, exit_status: 0, output: "all clean"),
          result(name: "test", status: :fail, output: "1 test, 1 failure")
        ])

      prompt = RepairPrompt.build(item(), verdict, 1, 2)

      assert prompt =~ "check: test"
      assert prompt =~ "1 test, 1 failure"
      refute prompt =~ "credo"
      refute prompt =~ "all clean"
    end

    test "surfaces the task id and the attempt counter" do
      prompt = RepairPrompt.build(item(), verdict([result([])]), 2, 3)

      assert prompt =~ "task 11"
      assert prompt =~ "repair attempt 2 of 3"
    end

    test "instructs the agent not to grade its own work" do
      prompt = RepairPrompt.build(item(), verdict([result([])]), 1, 1)

      assert prompt =~ ~r/do not run the verification/i
      assert prompt =~ ~r/harness re-runs the full stack and grades the result/i
    end

    test "renders the failure kind for timed-out and not-launched checks" do
      verdict =
        verdict([
          result(name: "dialyzer", kind: :timed_out, exit_status: nil, output: "slow"),
          result(name: "sobelow", kind: :not_launched, exit_status: nil, output: "[harness] not found")
        ])

      prompt = RepairPrompt.build(item(), verdict, 1, 1)

      assert prompt =~ "timed out"
      assert prompt =~ "could not launch"
    end

    test "tail-truncates oversized check output" do
      big = String.duplicate("x", 20_000)

      prompt = RepairPrompt.build(item(), verdict([result(output: big)]), 1, 1)

      assert prompt =~ "showing the last 6000"
      assert byte_size(prompt) < 12_000
    end

    test "keeps a check that produced no output readable" do
      prompt = RepairPrompt.build(item(), verdict([result(output: "   ")]), 1, 1)

      assert prompt =~ "no output"
    end
  end

  defp item, do: %Item{id: "11", title: "Autonomous repair loop", prompt: "do the thing", agent: :claude}

  defp verdict(results), do: %Verdict{status: :fail, results: results}

  defp result(overrides) do
    struct!(
      %Result{name: "test", command: "mix", status: :fail, kind: :exited, exit_status: 2, output: "boom"},
      overrides
    )
  end
end
