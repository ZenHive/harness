defmodule Harness.Benchmark.Item do
  @moduledoc """
  Minimal domain-tagged benchmark corpus item shape.

  Task 117 extends this with version, task spec, and check-stack reference;
  domain tags are declared here so corpus items and run records share one type.
  """

  alias Harness.CapabilityDomain

  @enforce_keys [:id, :domains]
  defstruct [:id, domains: []]

  @typedoc "A benchmark corpus item carrying declared capability domains."
  @type t :: %__MODULE__{
          id: String.t(),
          domains: [CapabilityDomain.t()]
        }

  @doc "Builds a corpus item after validating its domain tags."
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(fields) when is_list(fields) do
    with {:ok, domains} <- CapabilityDomain.validate(Keyword.get(fields, :domains, [])) do
      {:ok, struct!(__MODULE__, fields |> Map.new() |> Map.put(:domains, domains))}
    end
  end
end
