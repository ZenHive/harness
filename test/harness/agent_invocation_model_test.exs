defmodule Harness.AgentInvocationModelTest do
  @moduledoc """
  Locks the model pin on every real `%Invocation{}` construction in `lib/`.

  Model-capable adapters reject a nil model at the driver gate
  (`Harness.AgentAdapter.validate_model/2`), so an invocation built without a
  `model:` key can never spawn — it fails with `{:model_required, adapter}` at
  run time, not at compile time. The cron orchestrator and the facet scout both
  shipped that way and silently blocked autonomous dispatch; this test makes the
  next such site fail in the suite instead of in an operator's log.

  A construction is any struct literal that sets `prompt:` — the field every
  real invocation carries. Pattern matches (`%Invocation{} = invocation`) set no
  keys and are not construction sites.
  """

  use ExUnit.Case, async: true

  @invocation_alias [:Invocation]
  @full_alias [:Harness, :AgentAdapter, :Invocation]

  test "every invocation built with a prompt also pins a model" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           "an %Invocation{} without model: cannot spawn on a model-capable adapter; " <>
             "unpinned sites: #{inspect(offenders)}"
  end

  defp offenders_in_file(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], &collect_offender(&1, &2, file))
    |> elem(1)
    |> Enum.reverse()
  end

  defp collect_offender(node, acc, file) do
    case invocation_keys(node) do
      {:ok, line, keys} -> {node, prepend_unpinned(acc, file, line, keys)}
      :error -> {node, acc}
    end
  end

  defp prepend_unpinned(acc, file, line, keys) do
    if :prompt in keys and :model not in keys, do: ["#{file}:#{line}" | acc], else: acc
  end

  defp invocation_keys({:%, meta, [{:__aliases__, _, alias_}, {:%{}, _, kvs}]})
       when alias_ in [@invocation_alias, @full_alias] and is_list(kvs) do
    {:ok, Keyword.get(meta, :line, 0), Enum.map(kvs, fn {k, _v} -> k end)}
  end

  defp invocation_keys(_node), do: :error
end
