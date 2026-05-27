defmodule Harness.Run.FailureClass do
  @moduledoc """
  Classifies a settled failed `Harness.Run.Result` for retry policy.

  Three classes drive retry behaviour:

    * `:transient` — infrastructure flakiness (crashed step task, check timeout).
      Worth retrying with capped exponential backoff.
    * `:quota_exhausted` — the agent hit a subscription cap or rate limit. Not
      worth retrying on a useful timescale; stop and hand off to fail-over.
    * `:terminal` — a genuine task outcome (red checks, no diff, cancellation).
      Never retry.
  """

  alias Harness.AgentAdapter.Outcome
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  @typedoc "How retry policy should treat a failure."
  @type t :: :transient | :quota_exhausted | :terminal

  @doc """
  Classifies `result`. Only `:failed` results are classified; `:done` is `:terminal`.
  """
  @spec classify(Result.t(), RetryPolicy.t()) :: t()
  def classify(%Result{state: :failed} = result, %RetryPolicy{} = policy) do
    cond do
      quota_exhausted?(result, policy) -> :quota_exhausted
      transient?(result) -> :transient
      true -> :terminal
    end
  end

  def classify(%Result{state: :done}, _policy), do: :terminal

  @spec quota_exhausted?(Result.t(), RetryPolicy.t()) :: boolean()
  defp quota_exhausted?(result, policy) do
    texts = collect_text(result)
    Enum.any?(policy.quota_patterns, &pattern_match?(&1, texts))
  end

  @spec transient?(Result.t()) :: boolean()
  defp transient?(result) do
    flaky_red?(result) or
      crashed_step?(result.reason) or
      match?({:verification_failed, _}, result.reason) or
      match?({:worktree_failed, _}, result.reason) or
      match?({:commit_failed, _}, result.reason) or
      port_error?(result.agent_outcome)
  end

  @spec flaky_red?(Result.t()) :: boolean()
  defp flaky_red?(%{reason: :verification_red, verdict: verdict}), do: flaky_verdict?(verdict)
  defp flaky_red?(_), do: false

  @spec crashed_step?(Result.reason()) :: boolean()
  defp crashed_step?(reason) do
    match?({:driver_crashed, _}, reason) or match?({:verifier_crashed, _}, reason)
  end

  @spec flaky_verdict?(Verdict.t() | nil) :: boolean()
  defp flaky_verdict?(%Verdict{results: results}) do
    Enum.any?(results, &match?(%CheckResult{status: :fail, kind: :timed_out}, &1))
  end

  defp flaky_verdict?(_), do: false

  @spec port_error?(Outcome.t() | nil) :: boolean()
  defp port_error?(%Outcome{kind: {:error, _}}), do: true
  defp port_error?(_), do: false

  # Quota signals appear in an agent transcript's tail (the final assistant
  # message + result envelope, e.g. Claude's `"Credit balance is too low"` or
  # an HTTP 429 error) — never in the middle. Matching the entire transcript
  # against quota regexes is wildly false-positive-prone: agents routinely
  # display source code and docs that contain words like `quota`, `rate limit`,
  # and `subscription` (e.g. harness's own AgentRegistry moduledoc literally
  # says "subscription quota exhausted"). Limiting the matched window to the
  # trailing 4 KiB preserves real terminal error detection while skipping the
  # mid-run source-read noise. Same logic applies to verification check output
  # (e.g. `mix test.json` stdout can echo file paths and string literals from
  # the codebase under test).
  @text_tail_bytes 4 * 1024

  @spec collect_text(Result.t()) :: [String.t()]
  defp collect_text(%Result{} = result) do
    [
      outcome_text(result.agent_outcome),
      verdict_text(result.verdict),
      reason_text(result.reason)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
  end

  @spec outcome_text(Outcome.t() | nil) :: String.t()
  defp outcome_text(%Outcome{output: output}) when is_binary(output), do: tail(output)
  defp outcome_text(_), do: ""

  @spec verdict_text(Verdict.t() | nil) :: [String.t()]
  defp verdict_text(%Verdict{results: results}) do
    Enum.map(results, &tail(&1.output || ""))
  end

  defp verdict_text(_), do: []

  @spec tail(String.t()) :: String.t()
  defp tail(text) when is_binary(text) do
    size = byte_size(text)

    if size > @text_tail_bytes do
      binary_part(text, size - @text_tail_bytes, @text_tail_bytes)
    else
      text
    end
  end

  @spec reason_text(Result.reason()) :: String.t()
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text({tag, reason}) do
    "#{tag} #{inspect(reason)}"
  end

  @spec pattern_match?(Regex.t(), [String.t()]) :: boolean()
  defp pattern_match?(pattern, texts) do
    Enum.any?(texts, &Regex.match?(pattern, &1))
  end
end
