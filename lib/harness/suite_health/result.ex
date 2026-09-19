defmodule Harness.SuiteHealth.Result do
  @moduledoc """
  Raw full-suite health-check witness for one registered project.

  Harness counts pass/fail, exit code, and failing-test identifiers only —
  never classifies flakes or gates dispatch on this fact.
  """

  # Mirrors the `skip_reason` column width in
  # priv/repo/migrations/20260707120000_add_suite_health_results.exs.
  @skip_reason_limit 255
  @truncation_marker "…"

  @enforce_keys [:project_name, :checked_at]
  defstruct [
    :project_name,
    :checked_at,
    :passed,
    :exit_code,
    :command,
    :base_sha,
    :skip_reason,
    failing_tests: [],
    languages: ""
  ]

  @type failing_test :: %{
          required(:name) => String.t(),
          optional(:file) => String.t(),
          optional(:line) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          project_name: String.t(),
          checked_at: DateTime.t(),
          passed: boolean() | nil,
          exit_code: non_neg_integer() | nil,
          command: String.t() | nil,
          base_sha: String.t() | nil,
          skip_reason: String.t() | nil,
          failing_tests: [failing_test()],
          languages: String.t()
        }

  @doc "Builds a completed witness from a suite run."
  @spec build(String.t(), keyword()) :: t()
  def build(project_name, opts) when is_binary(project_name) and is_list(opts) do
    %__MODULE__{
      project_name: project_name,
      checked_at: Keyword.get(opts, :checked_at, DateTime.utc_now(:millisecond)),
      passed: Keyword.get(opts, :passed),
      exit_code: Keyword.get(opts, :exit_code),
      command: Keyword.get(opts, :command),
      base_sha: Keyword.get(opts, :base_sha),
      skip_reason: Keyword.get(opts, :skip_reason),
      failing_tests: Keyword.get(opts, :failing_tests, []),
      languages: Keyword.get(opts, :languages, "")
    }
  end

  @doc """
  Builds a skipped witness — no suite was executed.

  The reason is truncated to `skip_reason_limit/0`. Callers pass
  `inspect(reason)` of a bootstrap failure, which carries the whole mix output
  and routinely runs to thousands of characters, while the column is a
  `varchar(255)`. Before this bound, such a witness was rejected by Postgres
  with `22001 string_data_right_truncation`, the poller logged a warning and
  moved on, and — because the table is keyed on `project_name` and written by
  upsert — the stale previous row stayed visible in the dashboard with its old
  `checked_at`. A check that could not run must still leave a fact behind.
  """
  @spec skipped(String.t(), String.t(), keyword()) :: t()
  def skipped(project_name, reason, opts \\ []) when is_binary(project_name) and is_binary(reason) do
    build(project_name, Keyword.merge(opts, skip_reason: truncate_reason(reason), passed: nil, exit_code: nil))
  end

  @doc "Maximum stored length of `skip_reason`, matching the column width."
  @spec skip_reason_limit() :: pos_integer()
  def skip_reason_limit, do: @skip_reason_limit

  @spec truncate_reason(String.t()) :: String.t()
  defp truncate_reason(reason) do
    if String.length(reason) <= @skip_reason_limit do
      reason
    else
      String.slice(reason, 0, @skip_reason_limit - String.length(@truncation_marker)) <> @truncation_marker
    end
  end

  @doc "Serializes a witness to a plain map for persistence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      project_name: result.project_name,
      checked_at: result.checked_at,
      passed: result.passed,
      exit_code: result.exit_code,
      command: result.command,
      base_sha: result.base_sha,
      skip_reason: result.skip_reason,
      failing_tests: result.failing_tests,
      languages: result.languages
    }
  end
end
