defmodule Harness.ProjectCache.Recipe do
  @moduledoc """
  Validated, project-owned preparation recipe. Commands are trusted shell commands,
  not check hints. Inputs default to the complete tracked tree; narrowing them is
  an explicit compatibility contract owned by the project.
  """

  @defaults %{
    "inputs" => ["."],
    "exclude_inputs" => [],
    "env" => %{},
    "env_inputs" => nil,
    "timeout_ms" => 1_800_000,
    "version" => "1",
    "restore_commands" => []
  }
  @required ~w(commands paths identity_commands)

  @doc "Normalizes string-keyed recipes; nil disables preparation."
  @spec normalize(term()) :: {:ok, map() | nil} | {:error, :invalid_cache_preparation}
  def normalize(nil), do: {:ok, nil}

  def normalize(recipe) when is_map(recipe) and not is_struct(recipe) do
    recipe = Map.merge(@defaults, recipe)

    if valid?(recipe), do: {:ok, recipe}, else: {:error, :invalid_cache_preparation}
  end

  def normalize(_recipe), do: {:error, :invalid_cache_preparation}

  @doc "Whether a path names a relative descendant without traversal or git metadata."
  @spec relative_path?(term()) :: boolean()
  def relative_path?(path) when is_binary(path) and path != "" do
    Path.type(path) == :relative and
      Enum.all?(Path.split(path), &(&1 not in [".", "..", ".git", ".harness"])) and
      not String.contains?(path, <<0>>)
  end

  def relative_path?(_path), do: false

  @spec valid?(map()) :: boolean()
  defp valid?(recipe) do
    Enum.sort(Map.keys(recipe)) == Enum.sort(Map.keys(@defaults) ++ @required) and
      strings?(recipe["commands"]) and strings?(recipe["identity_commands"]) and
      (recipe["restore_commands"] == [] or strings?(recipe["restore_commands"])) and
      paths?(recipe["paths"]) and inputs?(recipe["inputs"]) and exclusions?(recipe["exclude_inputs"]) and
      options?(recipe)
  end

  @spec options?(map()) :: boolean()
  defp options?(recipe) do
    environment?(recipe["env"]) and env_inputs?(recipe["env_inputs"]) and is_integer(recipe["timeout_ms"]) and
      recipe["timeout_ms"] > 0 and is_binary(recipe["version"])
  end

  @spec env_inputs?(term()) :: boolean()
  defp env_inputs?(nil), do: true
  defp env_inputs?([]), do: true
  defp env_inputs?(inputs), do: strings?(inputs)

  @spec strings?(term()) :: boolean()
  defp strings?([_ | _] = values),
    do: Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "" and not String.contains?(&1, <<0>>)))

  defp strings?(_values), do: false

  @spec paths?(term()) :: boolean()
  defp paths?(paths) do
    strings?(paths) and Enum.all?(paths, &(relative_path?(&1) and hd(Path.split(&1)) != "complete.json")) and
      not Enum.any?(paths, fn path ->
        Enum.any?(paths -- [path], &(path == &1 or String.starts_with?(path, &1 <> "/")))
      end)
  end

  @spec inputs?(term()) :: boolean()
  defp inputs?(inputs), do: strings?(inputs) and Enum.all?(inputs, &(&1 == "." or relative_path?(&1)))

  @spec exclusions?(term()) :: boolean()
  defp exclusions?([]), do: true

  defp exclusions?(paths) do
    strings?(paths) and
      Enum.all?(paths, &(relative_path?(&1) and ".harness-active" not in Path.split(&1)))
  end

  @spec environment?(term()) :: boolean()
  defp environment?(env) when is_map(env) and not is_struct(env) do
    Enum.all?(env, fn {key, value} ->
      is_binary(key) and key != "" and not String.contains?(key, ["=", <<0>>]) and
        is_binary(value) and not String.contains?(value, <<0>>)
    end)
  end

  defp environment?(_env), do: false
end
