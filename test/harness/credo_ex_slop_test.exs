defmodule Harness.CredoExSlopTest do
  use ExUnit.Case, async: true

  test "explicit Credo enabled list includes ExSlop.recommended_checks/0" do
    {config, _binding} = Code.eval_file(Path.expand("../../.credo.exs", __DIR__))

    enabled_checks =
      config
      |> get_in([:configs, Access.at(0), :checks, :enabled])
      |> Enum.map(fn {check, _opts} -> check end)

    missing = ExSlop.recommended_checks() -- enabled_checks

    assert missing == [],
           "ExSlop checks missing from .credo.exs enabled list: #{inspect(missing)}"
  end
end
