defmodule Harness.SuiteHealth.Result do
  @moduledoc """
  Raw full-suite health-check witness for one registered project.

  Harness counts pass/fail, exit code, and failing-test identifiers only —
  never classifies flakes or gates dispatch on this fact.
  """

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

  @doc "Builds a skipped witness — no suite was executed."
  @spec skipped(String.t(), String.t(), keyword()) :: t()
  def skipped(project_name, reason, opts \\ []) when is_binary(project_name) and is_binary(reason) do
    build(project_name, Keyword.merge(opts, skip_reason: reason, passed: nil, exit_code: nil))
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
