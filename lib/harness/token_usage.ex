defmodule Harness.TokenUsage do
  @moduledoc """
  Per-run token-usage facts parsed from a headless agent's raw transcript.

  Every adapter's wire format already carries token counts that harness
  captures verbatim in `%Harness.Run.LogRecord{}.agent_output` — this module
  parses them into a normalized, adapter-agnostic shape so an A/B comparison
  can weigh **token efficiency** (did the agent solve the task in 50k tokens or
  500k?) instead of only the binary pass/fail verdict. It is the input signal a
  future history-based router and predictive quota fail-over consume; it is
  **not** dollar accounting (agents run on flat subscriptions, so dollars are
  meaningless).

  ## Fields

    * `input` — non-cached prompt/input tokens
    * `output` — completion tokens
    * `cache_read` — cached prompt tokens read (Anthropic-shaped agents, Pi)
    * `cache_creation` — cache-write tokens (Anthropic-shaped agents, Pi)
    * `total` — sum of whichever components above are present

  Every field is `nil` when the wire format did not report it. A format that
  carries no usage at all parses to `empty/0` (all-`nil`) — never a crash.

  ## Per-adapter strategy

    * `:claude` / `:cursor` — Anthropic-shaped `stream-json`. Prefers the
      terminal `result` event's cumulative `usage`; falls back to summing each
      `assistant` message's `message.usage` when no result usage is present.
    * `:codex` — sums the `usage` on each `turn.completed` event.
    * `:pi` — `message_update` snapshots restate a message's running usage, so
      usage is deduplicated by `responseId` (last snapshot wins per message)
      then summed across messages.
    * `:grok` — best-effort `usage` on the terminal `end` event.
    * `:antigravity` — plain text, no usage → `empty/0`.
    * `nil` / unknown — test doubles and unregistered adapters → `empty/0`.

  Repair attempts accumulate via `add/2`: `Harness.Run` parses each attempt's
  outcome as it settles and sums them, so a multi-attempt run's total burn is
  attributable.
  """

  @typedoc "Adapter atom keys mirror `Harness.AgentRegistry.agents/0`; `nil` is an unregistered adapter."
  @type agent_kind :: :claude | :codex | :cursor | :grok | :pi | :antigravity | nil

  @typedoc "Normalized per-run token usage. Each field is `nil` when unreported."
  @type t :: %__MODULE__{
          input: non_neg_integer() | nil,
          output: non_neg_integer() | nil,
          cache_read: non_neg_integer() | nil,
          cache_creation: non_neg_integer() | nil,
          total: non_neg_integer() | nil
        }

  defstruct [:input, :output, :cache_read, :cache_creation, :total]

  @doc "Returns an all-`nil` usage — the canonical \"no data measured\" value."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Returns whether any component field carries a count."
  @spec measured?(t()) :: boolean()
  def measured?(%__MODULE__{input: nil, output: nil, cache_read: nil, cache_creation: nil}), do: false
  def measured?(%__MODULE__{}), do: true

  @doc """
  Sums two usages component-wise, treating `nil` as absent.

  `nil + nil = nil`, `nil + n = n` — so adding an empty usage is a no-op and a
  measured field is never erased. `total` is recomputed from the result.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    put_total(%__MODULE__{
      input: add_field(a.input, b.input),
      output: add_field(a.output, b.output),
      cache_read: add_field(a.cache_read, b.cache_read),
      cache_creation: add_field(a.cache_creation, b.cache_creation)
    })
  end

  @doc """
  Parses `output` (a raw agent transcript) into a normalized usage for `kind`.

  Tolerant by construction: a transcript with no usage, malformed lines, or a
  non-binary `output` all parse to `empty/0` rather than raising.
  """
  @spec parse(agent_kind(), term()) :: t()
  def parse(_kind, output) when not is_binary(output), do: empty()
  def parse(:claude, output), do: parse_anthropic_stream(output)
  def parse(:cursor, output), do: parse_anthropic_stream(output)
  def parse(:codex, output), do: parse_codex(output)
  def parse(:pi, output), do: parse_pi(output)
  def parse(:grok, output), do: parse_grok(output)
  def parse(_other, _output), do: empty()

  # ── Per-adapter extraction ──────────────────────────────────────────────

  @spec parse_anthropic_stream(binary()) :: t()
  defp parse_anthropic_stream(output) do
    objects = json_objects(output)

    case result_usage(objects) do
      %{} = usage -> from_anthropic_usage(usage)
      nil -> sum_assistant_usage(objects)
    end
  end

  @spec result_usage([map()]) :: map() | nil
  defp result_usage(objects) do
    objects
    |> Enum.filter(&(&1["type"] == "result"))
    |> Enum.map(& &1["usage"])
    |> Enum.find(&is_map/1)
  end

  @spec sum_assistant_usage([map()]) :: t()
  defp sum_assistant_usage(objects) do
    objects
    |> Enum.filter(&(&1["type"] == "assistant"))
    |> Enum.map(&get_in(&1, ["message", "usage"]))
    |> Enum.filter(&is_map/1)
    |> sum_usages(&from_anthropic_usage/1)
  end

  @spec parse_codex(binary()) :: t()
  defp parse_codex(output) do
    output
    |> json_objects()
    |> Enum.filter(&(&1["type"] == "turn.completed"))
    |> Enum.map(& &1["usage"])
    |> Enum.filter(&is_map/1)
    |> sum_usages(&from_codex_usage/1)
  end

  @spec parse_pi(binary()) :: t()
  defp parse_pi(output) do
    output
    |> json_objects()
    |> Enum.flat_map(&pi_usage_entry/1)
    |> Enum.reduce(%{}, fn {response_id, usage}, acc -> Map.put(acc, response_id, usage) end)
    |> Map.values()
    |> sum_usages(&from_pi_usage/1)
  end

  # Pi restates a message's running usage in every `message_update`; the full
  # `message` snapshot carries both the usage and its `responseId`, so keying on
  # `responseId` (last write wins) collapses the restatements to one per message.
  @spec pi_usage_entry(map()) :: [{term(), map()}]
  defp pi_usage_entry(%{"message" => %{"usage" => usage, "responseId" => response_id}}) when is_map(usage) do
    [{response_id, usage}]
  end

  defp pi_usage_entry(_object), do: []

  @spec parse_grok(binary()) :: t()
  defp parse_grok(output) do
    output
    |> json_objects()
    |> Enum.filter(&(&1["type"] == "end"))
    |> Enum.map(& &1["usage"])
    |> Enum.filter(&is_map/1)
    |> sum_usages(&from_generic_usage/1)
  end

  # ── Usage-map → struct ──────────────────────────────────────────────────

  @spec from_anthropic_usage(map()) :: t()
  defp from_anthropic_usage(usage) do
    put_total(%__MODULE__{
      input: count(usage["input_tokens"]),
      output: count(usage["output_tokens"]),
      cache_read: count(usage["cache_read_input_tokens"]),
      cache_creation: count(usage["cache_creation_input_tokens"])
    })
  end

  @spec from_codex_usage(map()) :: t()
  defp from_codex_usage(usage) do
    put_total(%__MODULE__{
      input: count(usage["input_tokens"]),
      output: count(usage["output_tokens"]),
      cache_read: count(usage["cached_input_tokens"])
    })
  end

  @spec from_pi_usage(map()) :: t()
  defp from_pi_usage(usage) do
    put_total(%__MODULE__{
      input: count(usage["input"]),
      output: count(usage["output"]),
      cache_read: count(usage["cacheRead"]),
      cache_creation: count(usage["cacheWrite"])
    })
  end

  # Grok's terminal `end` event usage shape is not pinned across releases;
  # accept the common Anthropic- and OpenAI-style field names defensively.
  @spec from_generic_usage(map()) :: t()
  defp from_generic_usage(usage) do
    put_total(%__MODULE__{
      input: count(usage["input_tokens"] || usage["input"] || usage["promptTokens"]),
      output: count(usage["output_tokens"] || usage["output"] || usage["completionTokens"]),
      cache_read: count(usage["cache_read_input_tokens"] || usage["cacheRead"])
    })
  end

  # ── Shared helpers ──────────────────────────────────────────────────────

  @spec sum_usages([map()], (map() -> t())) :: t()
  defp sum_usages(usages, from_usage) do
    Enum.reduce(usages, empty(), fn usage, acc -> add(acc, from_usage.(usage)) end)
  end

  @spec json_objects(binary()) :: [map()]
  defp json_objects(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end
    end)
  end

  @spec count(term()) :: non_neg_integer() | nil
  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  @spec add_field(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer() | nil
  defp add_field(nil, nil), do: nil
  defp add_field(nil, b), do: b
  defp add_field(a, nil), do: a
  defp add_field(a, b), do: a + b

  @spec put_total(t()) :: t()
  defp put_total(%__MODULE__{} = usage) do
    components = Enum.filter([usage.input, usage.output, usage.cache_read, usage.cache_creation], &is_integer/1)
    total = if components == [], do: nil, else: Enum.sum(components)
    %{usage | total: total}
  end
end
