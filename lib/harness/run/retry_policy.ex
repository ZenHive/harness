defmodule Harness.Run.RetryPolicy do
  @moduledoc """
  Mechanical backoff arithmetic for re-attempting work that failed for
  infrastructure reasons (BEAM death, port spawn failure, a worktree race).

  This module is deliberately judgment-free: a run that reached a settled
  verdict — green, red, reviewer-stuck — is never re-run by policy code, and
  nothing here inspects agent output. Deciding what a failure *means* is the
  cross-family reviewer's job (`docs/reviewer-pair-architecture.md`); the only
  thing left here is the arithmetic of "how long to wait before the next
  mechanical attempt".

  Knobs default from `:harness, :retry_policy` application config.
  """

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 60_000
  @default_multiplier 2.0

  @typedoc """
  Policy knobs.

    * `max_retries` — how many *retries* after the first attempt (not total runs).
    * `base_delay_ms` / `max_delay_ms` / `multiplier` — capped exponential backoff.
  """
  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          multiplier: float()
        }

  @enforce_keys [:max_retries, :base_delay_ms, :max_delay_ms, :multiplier]
  defstruct [:max_retries, :base_delay_ms, :max_delay_ms, :multiplier]

  @doc """
  Builds a policy from `opts` or application config defaults.

  Options: `:max_retries`, `:base_delay_ms`, `:max_delay_ms`, `:multiplier`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    defaults = Application.get_env(:harness, :retry_policy, [])

    %__MODULE__{
      max_retries: fetch(opts, defaults, :max_retries, @default_max_retries),
      base_delay_ms: fetch(opts, defaults, :base_delay_ms, @default_base_delay_ms),
      max_delay_ms: fetch(opts, defaults, :max_delay_ms, @default_max_delay_ms),
      multiplier: fetch(opts, defaults, :multiplier, @default_multiplier)
    }
  end

  @doc "Capped exponential backoff delay in ms for failure attempt `attempt` (1-based)."
  @spec backoff_ms(t(), pos_integer()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{base_delay_ms: base, max_delay_ms: max_delay, multiplier: mult}, attempt)
      when attempt >= 1 do
    delay = trunc(base * :math.pow(mult, attempt - 1))
    delay |> max(0) |> min(max_delay)
  end

  @doc """
  Runs `fun`, re-invoking it on an `{:error, _}` result with capped backoff
  (`backoff_ms/2`) until `policy.max_retries` is exhausted, then returns the last
  error. Any non-error result short-circuits and is returned as-is.

  Mechanical infrastructure retry only — `fun` is expected to fail for
  infrastructure reasons (a worktree race, a port spawn). It never inspects agent
  output or a settled verdict.
  """
  @spec retry((-> result), t()) :: result when result: term()
  def retry(fun, %__MODULE__{} = policy) when is_function(fun, 0), do: do_retry(fun, policy, 1)

  @spec do_retry((-> term()), t(), pos_integer()) :: term()
  defp do_retry(fun, %__MODULE__{} = policy, attempt) do
    case fun.() do
      {:error, _reason} = error when attempt > policy.max_retries ->
        error

      {:error, _reason} ->
        Process.sleep(backoff_ms(policy, attempt))
        do_retry(fun, policy, attempt + 1)

      other ->
        other
    end
  end

  @spec fetch(keyword(), keyword(), atom(), term()) :: term()
  defp fetch(opts, defaults, key, fallback) do
    Keyword.get(opts, key, Keyword.get(defaults, key, fallback))
  end
end
