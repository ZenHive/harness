defmodule Harness.ProjectRegistry.PersistenceCodecTest do
  @moduledoc """
  Unit tests for the 2026-08-26 cold-boot registry wipe: Persistence.decode_term/1
  delegates to SafeTerm.decode/1, so a Project ETF whose atoms the reading node
  lacks is restored instead of discarded. Persistence.list/0 still needs a DB
  (see the :integration suite); this file pins the decode class without Postgres.

  The atom `Elixir.Harness.Project` cannot be unloaded in this VM. Boot-time
  `Code.ensure_loaded!/1` (see `Harness.SafeTermTest`) is the module-existence
  pin; this file proves `:safe` rejection plus SafeTerm restore of a
  Project-shaped payload.
  """

  use ExUnit.Case, async: true

  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.SafeTerm

  test "a persisted Project ETF round-trips as %Harness.Project{}" do
    project = ProjectFixture.from_repo("/tmp/reg", name: "reg")
    payload = :erlang.term_to_binary(project)

    assert {:ok, ^project} = SafeTerm.decode(payload)
    assert %Project{name: "reg"} = project
  end

  test "SafeTerm.decode restores a Project payload that :safe rejects for a missing field atom" do
    known = "zzrevrcoldx"
    cold = "projcoldatm"
    assert byte_size(known) == byte_size(cold)
    assert_raise ArgumentError, fn -> String.to_existing_atom(cold) end

    project =
      ProjectFixture.from_repo("/tmp/cold-reg", name: "cold-reg", reviewer: String.to_atom(known))

    payload = :erlang.term_to_binary(project)
    replaced = replace_etf_atom_name(payload, known, cold)

    assert_raise ArgumentError, fn -> :erlang.binary_to_term(replaced, [:safe]) end
    assert {:ok, decoded} = SafeTerm.decode(replaced)
    assert decoded.__struct__ == Project
    assert decoded.name == "cold-reg"
    assert Atom.to_string(decoded.reviewer) == cold
  end

  # Rewrite only the atom-name bytes that sit behind an ETF atom tag, so a
  # coincidental substring in another term cannot corrupt the payload.
  @spec replace_etf_atom_name(binary(), String.t(), String.t()) :: binary()
  defp replace_etf_atom_name(payload, from, to) when byte_size(from) == byte_size(to) do
    replacements = [
      {<<119, byte_size(from), from::binary>>, <<119, byte_size(to), to::binary>>},
      {<<100, byte_size(from)::16, from::binary>>, <<100, byte_size(to)::16, to::binary>>},
      {<<118, byte_size(from)::16, from::binary>>, <<118, byte_size(to)::16, to::binary>>}
    ]

    case Enum.find(replacements, fn {from_bytes, _} -> :binary.match(payload, from_bytes) != :nomatch end) do
      {from_bytes, to_bytes} -> :binary.replace(payload, from_bytes, to_bytes)
      nil -> flunk("ETF atom #{inspect(from)} not found in payload")
    end
  end
end
