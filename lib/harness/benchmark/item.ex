defmodule Harness.Benchmark.Item do
  @moduledoc """
  A fixed capability-benchmark corpus item.

  Benchmark items live outside the mutable roadmap. Each item is a stable,
  versioned task contract plus the project/check-stack reference that grades it.
  Roadmap tasks are consumed; benchmark items are repeatable.
  """

  alias Harness.CapabilityDomain

  @enforce_keys [
    :id,
    :version,
    :domains,
    :intent,
    :acceptance_criteria,
    :target_project,
    :check_stack,
    :expected_green
  ]

  defstruct [
    :id,
    :version,
    :intent,
    :target_project,
    :check_stack,
    :expected_green,
    domains: [],
    acceptance_criteria: []
  ]

  @typedoc "A benchmark corpus item carrying a stable task contract and grader reference."
  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          domains: [CapabilityDomain.t()],
          intent: String.t(),
          acceptance_criteria: [String.t()],
          target_project: String.t(),
          check_stack: String.t(),
          expected_green: boolean()
        }

  @doc "Builds a corpus item after validating its domain tags."
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(fields) when is_list(fields) do
    with :ok <- require_fields(fields),
         :ok <- validate_non_empty_string(fields, :id),
         :ok <- validate_positive_integer(fields, :version),
         {:ok, domains} <- CapabilityDomain.validate(Keyword.fetch!(fields, :domains)),
         :ok <- validate_non_empty_string(fields, :intent),
         :ok <- validate_string_list(fields, :acceptance_criteria),
         :ok <- validate_non_empty_string(fields, :target_project),
         :ok <- validate_non_empty_string(fields, :check_stack),
         :ok <- validate_boolean(fields, :expected_green) do
      item =
        fields
        |> Map.new()
        |> Map.put(:domains, domains)

      {:ok, struct!(__MODULE__, item)}
    end
  end

  @required_fields [
    :id,
    :version,
    :domains,
    :intent,
    :acceptance_criteria,
    :target_project,
    :check_stack,
    :expected_green
  ]

  @spec require_fields(keyword()) :: :ok | {:error, {:missing_field, atom()}}
  defp require_fields(fields) do
    case Enum.find(@required_fields, &(not Keyword.has_key?(fields, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  @spec validate_non_empty_string(keyword(), atom()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_non_empty_string(fields, key) do
    case Keyword.fetch!(fields, key) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec validate_positive_integer(keyword(), atom()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_positive_integer(fields, key) do
    case Keyword.fetch!(fields, key) do
      value when is_integer(value) and value > 0 -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec validate_string_list(keyword(), atom()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_string_list(fields, key) do
    case Keyword.fetch!(fields, key) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
          :ok
        else
          {:error, {:invalid_field, key, values}}
        end

      value ->
        {:error, {:invalid_field, key, value}}
    end
  end

  @spec validate_boolean(keyword(), atom()) :: :ok | {:error, {:invalid_field, atom(), term()}}
  defp validate_boolean(fields, key) do
    case Keyword.fetch!(fields, key) do
      value when is_boolean(value) -> :ok
      value -> {:error, {:invalid_field, key, value}}
    end
  end
end
