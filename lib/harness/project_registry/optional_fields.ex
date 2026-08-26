defmodule Harness.ProjectRegistry.OptionalFields do
  @moduledoc false

  alias Harness.Project

  @fields [
    {:concurrency_cap, nil},
    {:pollution_allowlist, nil},
    {:warm_paths, []},
    {:landing_policy, :manual},
    {:target_branch, nil},
    {:reviewer, nil},
    {:test_db_isolation_env, nil},
    {:tooling_baseline_overrides, %{}}
  ]

  @errors %{
    concurrency_cap: :invalid_concurrency_cap,
    pollution_allowlist: :invalid_pollution_allowlist,
    warm_paths: :invalid_warm_paths,
    landing_policy: :invalid_landing_policy,
    target_branch: :invalid_target_branch,
    reviewer: :invalid_reviewer,
    test_db_isolation_env: :invalid_test_db_isolation_env,
    tooling_baseline_overrides: :invalid_tooling_baseline_overrides
  }

  @spec fetch(map()) :: {:ok, map()} | {:error, {:invalid_project, term()}}
  def fetch(entry) when is_map(entry) do
    Enum.reduce_while(@fields, {:ok, %{}}, &fetch_one(entry, &1, &2))
  end

  @spec validate(Project.t()) :: :ok | {:error, {:invalid_project, term()}}
  def validate(%Project{} = project) do
    case fetch(Map.from_struct(project)) do
      {:ok, _fields} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec fetch_one(map(), {atom(), term()}, {:ok, map()}) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {:invalid_project, term()}}}
  defp fetch_one(entry, {field, default}, {:ok, acc}) do
    case cast(field, Map.get(entry, field, default)) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
      {:error, _} = error -> {:halt, error}
    end
  end

  @spec cast(atom(), term()) :: {:ok, term()} | {:error, {:invalid_project, term()}}
  defp cast(:concurrency_cap, nil), do: {:ok, nil}
  defp cast(:concurrency_cap, cap) when is_integer(cap) and cap > 0, do: {:ok, cap}
  defp cast(:concurrency_cap, other), do: invalid(:concurrency_cap, other)

  defp cast(:pollution_allowlist, nil), do: {:ok, nil}
  defp cast(:pollution_allowlist, list), do: string_list(:pollution_allowlist, list)

  defp cast(:warm_paths, list), do: string_list(:warm_paths, list)

  defp cast(:landing_policy, policy) when policy in [:manual, :auto], do: {:ok, policy}
  defp cast(:landing_policy, other), do: invalid(:landing_policy, other)

  defp cast(:target_branch, nil), do: {:ok, nil}
  defp cast(:target_branch, branch) when is_binary(branch), do: {:ok, branch}
  defp cast(:target_branch, other), do: invalid(:target_branch, other)

  defp cast(:reviewer, reviewer) when is_atom(reviewer), do: {:ok, reviewer}
  defp cast(:reviewer, other), do: invalid(:reviewer, other)

  defp cast(:test_db_isolation_env, nil), do: {:ok, nil}
  defp cast(:test_db_isolation_env, false), do: {:ok, false}
  defp cast(:test_db_isolation_env, :none), do: {:ok, :none}
  defp cast(:test_db_isolation_env, name) when is_binary(name), do: {:ok, name}
  defp cast(:test_db_isolation_env, other), do: invalid(:test_db_isolation_env, other)

  defp cast(:tooling_baseline_overrides, map) when is_map(map) and not is_struct(map) do
    if Enum.all?(map, &string_pair?/1),
      do: {:ok, map},
      else: invalid(:tooling_baseline_overrides, map)
  end

  defp cast(:tooling_baseline_overrides, other), do: invalid(:tooling_baseline_overrides, other)

  @spec string_list(atom(), term()) :: {:ok, [String.t()]} | {:error, {:invalid_project, term()}}
  defp string_list(field, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: invalid(field, list)
  end

  defp string_list(field, other), do: invalid(field, other)

  @spec string_pair?({term(), term()}) :: boolean()
  defp string_pair?({key, value}), do: is_binary(key) and is_binary(value)

  @spec invalid(atom(), term()) :: {:error, {:invalid_project, {atom(), term()}}}
  defp invalid(field, value), do: {:error, {:invalid_project, {@errors[field], value}}}
end
