defmodule Harness.Run.RepairPrompt do
  @moduledoc """
  Renders a red verification verdict into a focused repair prompt for a resumed
  agent.

  When `Harness.Run`'s verification stack grades an agent's work red and repair
  attempts remain, the run resumes the **same** agent and hands it the prompt
  this module builds — the failing checks, their captured output, and the
  instruction to fix them. The objective check stack stays the grader, and the
  prompt tells the agent not to re-run it, so an agent iterating against this
  prompt is repairing its work, not grading it.

  The agent is resumed in the worktree it already worked in, so it still holds
  the original task context; the repair prompt is deliberately scoped to *what
  failed* rather than restating the task.

  Each failing check's output is tail-truncated to a bounded byte size. The
  prompt reaches the agent as a single command-line argument, and an unbounded
  check dump — a full `mix test` log — would breach the OS argument-length limit
  and the spawn would fail outright.
  """

  alias Harness.Roadmap.Item
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  # Per-check output cap. With five preset checks this stays well inside a
  # 256 KiB ARG_MAX even alongside the surrounding prose.
  @max_output_bytes 6_000

  @doc """
  Builds the repair prompt for a red `verdict` on `item`.

  `attempt` is the repair attempt about to be dispatched (1-based) and `max` the
  configured attempt cap, both surfaced to the agent so it knows how many shots
  remain. Only the verdict's failed results are rendered — a passed check never
  appears in the prompt.
  """
  @spec build(Item.t(), Verdict.t(), pos_integer(), pos_integer()) :: String.t()
  def build(%Item{} = item, %Verdict{results: results}, attempt, max)
      when is_integer(attempt) and attempt >= 1 and is_integer(max) and max >= 1 do
    failed = Enum.filter(results, &(&1.status == :fail))
    header(item, attempt, max, length(failed)) <> Enum.map_join(failed, "", &render_check/1)
  end

  @spec header(Item.t(), pos_integer(), pos_integer(), non_neg_integer()) :: String.t()
  defp header(%Item{id: id}, attempt, max, failed_count) do
    """
    harness verification graded your work on task #{id} red — repair attempt #{attempt} of #{max}.

    Fix every failing check listed below, then stop. Do not run the verification
    checks yourself: harness re-runs the full stack and grades the result — your
    job is only to repair the code. Leave your fixes in the working tree.

    #{failed_count} check(s) failed:
    """
  end

  @spec render_check(Result.t()) :: String.t()
  defp render_check(%Result{} = result) do
    """

    ──────── check: #{result.name} (#{result.command}) — #{status_line(result)} ────────

    #{output_or_placeholder(result.output)}
    """
  end

  @spec status_line(Result.t()) :: String.t()
  defp status_line(%Result{kind: :exited, exit_status: status}), do: "exited #{status}"
  defp status_line(%Result{kind: :timed_out}), do: "timed out"
  defp status_line(%Result{kind: :not_launched}), do: "could not launch"

  @spec output_or_placeholder(String.t()) :: String.t()
  defp output_or_placeholder(output) do
    case String.trim(output) do
      "" -> "(the check produced no output)"
      _trimmed -> truncate(output)
    end
  end

  @spec truncate(String.t()) :: String.t()
  defp truncate(output) when byte_size(output) <= @max_output_bytes, do: output

  defp truncate(output) do
    tail = binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)
    "[harness: showing the last #{@max_output_bytes} of #{byte_size(output)} bytes]\n" <> valid_utf8_tail(tail)
  end

  # binary_part/3 can slice mid-codepoint; drop leading bytes until the tail is
  # valid UTF-8 again (at most three).
  @spec valid_utf8_tail(binary()) :: binary()
  defp valid_utf8_tail(<<>>), do: <<>>

  defp valid_utf8_tail(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_tail(binary_part(bin, 1, byte_size(bin) - 1))
  end
end
