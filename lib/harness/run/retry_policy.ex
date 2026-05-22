defmodule Harness.Run.RetryPolicy do
  @moduledoc """
  Per-run retry policy: classify a failure, then retry, fail-over, or stop.

  Transient failures retry with capped exponential backoff. Quota exhaustion
  stops immediately for fail-over (no multi-hour backoff loop). Terminal failures
  are never retried.

  Inject at batch or run scope via `:retry_policy` — a `%RetryPolicy{}` struct or
  a keyword list passed to `new/1` / `from_opts/1`. Defaults come from
  `:harness, :retry_policy` application config.

      policy = RetryPolicy.new(max_retries: 2, base_delay_ms: 500)
      RetryPolicy.run(fn -> await_run() end, policy)
  """

  alias Harness.Run.FailureClass
  alias Harness.Run.Result

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 60_000
  @default_multiplier 2.0

  @typedoc """
  Policy knobs.

    * `max_retries` — how many *retries* after the first attempt (not total runs).
    * `base_delay_ms` / `max_delay_ms` / `multiplier` — capped exponential backoff.
    * `quota_patterns` — regexes matched against agent output and error text.
  """
  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          multiplier: float(),
          quota_patterns: [Regex.t()]
        }

  @typedoc """
  What to do after classifying a failure at `attempt`.

    * `{:retry, delay_ms, next_attempt}` — sleep `delay_ms`, then run again.
    * `{:failover, :quota_exhausted}` — stop retrying this agent; route elsewhere.
    * `{:stop, reason}` — give up (`:terminal`, `:max_attempts`, or `:quota_exhausted`
      when not using fail-over).
  """
  @type decision ::
          {:retry, non_neg_integer(), pos_integer()}
          | {:failover, :quota_exhausted}
          | {:stop, FailureClass.t() | :max_attempts}

  @enforce_keys [:max_retries, :base_delay_ms, :max_delay_ms, :multiplier, :quota_patterns]
  defstruct [
    :max_retries,
    :base_delay_ms,
    :max_delay_ms,
    :multiplier,
    :quota_patterns
  ]

  @doc """
  Builds a policy from `opts` or application config defaults.

  Options: `:max_retries`, `:base_delay_ms`, `:max_delay_ms`, `:multiplier`,
  `:quota_patterns`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = Application.get_env(:harness, :retry_policy, [])

    %__MODULE__{
      max_retries: fetch(opts, defaults, :max_retries, @default_max_retries),
      base_delay_ms: fetch(opts, defaults, :base_delay_ms, @default_base_delay_ms),
      max_delay_ms: fetch(opts, defaults, :max_delay_ms, @default_max_delay_ms),
      multiplier: fetch(opts, defaults, :multiplier, @default_multiplier),
      quota_patterns: Keyword.get(opts, :quota_patterns, Keyword.get(defaults, :quota_patterns, default_quota_patterns()))
    }
  end

  @doc "Resolves `:retry_policy` from run or batch options."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :retry_policy) do
      %__MODULE__{} = policy -> policy
      policy_opts when is_list(policy_opts) -> new(policy_opts)
      nil -> new([])
    end
  end

  @doc """
  Classifies `result` and returns the next action for failure `attempt` (1-based).

  The first run is attempt `1`; each retry bumps the attempt counter passed to
  `run/2`'s inner loop.
  """
  @spec decide(t(), FailureClass.t(), pos_integer()) :: decision()
  def decide(%__MODULE__{}, :quota_exhausted, _attempt), do: {:failover, :quota_exhausted}

  def decide(%__MODULE__{}, :terminal, _attempt), do: {:stop, :terminal}

  def decide(%__MODULE__{max_retries: max_retries} = policy, :transient, attempt) do
    if attempt > max_retries do
      {:stop, :max_attempts}
    else
      {:retry, backoff_ms(policy, attempt), attempt + 1}
    end
  end

  @doc """
  Runs `fun` until success, fail-over, or stop.

  `fun` must return a `Harness.Run.Result`. On `:done`, returns
  `{:ok, result, attempts}`. On quota exhaustion, `{:failover, result, :quota_exhausted}`.
  Otherwise `{:error, result, reason}`.
  """
  @spec run((-> Result.t()), t() | keyword()) ::
          {:ok, Result.t(), pos_integer()}
          | {:failover, Result.t(), :quota_exhausted}
          | {:error, Result.t(), term()}
  def run(fun, policy_or_opts \\ []) when is_function(fun, 0) do
    policy = policy_struct(policy_or_opts)
    do_run(fun, policy, 1)
  end

  @doc "Capped exponential backoff delay in ms for failure attempt `attempt`."
  @spec backoff_ms(t(), pos_integer()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{} = policy, attempt) when attempt >= 1, do: backoff_ms_impl(policy, attempt)

  @doc false
  @spec default_quota_patterns() :: [Regex.t()]
  def default_quota_patterns do
    [
      ~r/rate\s*limit/i,
      ~r/quota/i,
      ~r/usage\s*limit/i,
      ~r/billing_error/i,
      ~r/too many requests/i,
      ~r/\b429\b/,
      ~r/subscription.*(?:limit|exhausted|exceeded)/i
    ]
  end

  @spec policy_struct(t() | keyword()) :: t()
  defp policy_struct(%__MODULE__{} = policy), do: policy
  defp policy_struct(opts) when is_list(opts), do: new(opts)

  @spec do_run((-> Result.t()), t(), pos_integer()) ::
          {:ok, Result.t(), pos_integer()}
          | {:failover, Result.t(), :quota_exhausted}
          | {:error, Result.t(), term()}
  defp do_run(fun, policy, attempt) do
    case fun.() do
      %Result{state: :done} = result ->
        {:ok, result, attempt}

      %Result{state: :failed} = result ->
        class = FailureClass.classify(result, policy)

        case decide(policy, class, attempt) do
          {:retry, delay_ms, next_attempt} ->
            Process.sleep(delay_ms)
            do_run(fun, policy, next_attempt)

          {:failover, :quota_exhausted} ->
            {:failover, result, :quota_exhausted}

          {:stop, reason} ->
            {:error, result, reason}
        end
    end
  end

  @spec backoff_ms_impl(t(), pos_integer()) :: non_neg_integer()
  defp backoff_ms_impl(%{base_delay_ms: base, max_delay_ms: max, multiplier: mult}, attempt) do
    delay = trunc(base * :math.pow(mult, attempt - 1))
    min(max(delay, 0), max)
  end

  @spec fetch(keyword(), keyword(), atom(), term()) :: term()
  defp fetch(opts, defaults, key, fallback) do
    Keyword.get(opts, key, Keyword.get(defaults, key, fallback))
  end
end
