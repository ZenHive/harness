defmodule Harness.Run.Evidence do
  @moduledoc "Bounded snapshots of run-local evidence, retained independently of worktree cleanup."

  @root ".harness/evidence"
  @max_files 100
  @max_bytes 16_000_000
  @max_file_bytes 4_000_000

  @doc "Snapshots regular files only; records missing references and collection errors as facts."
  @spec capture(String.t(), map()) :: map()
  def capture(worktree, checks) do
    {files, errors, _bytes} = walk(worktree, ".harness", {%{}, [], 0}, 0)
    missing = checks |> references() |> Enum.reject(&Map.has_key?(files, &1))

    %{
      "files" => files,
      "count" => map_size(files),
      "errors" => Enum.reverse(errors),
      "missing" => missing
    }
  end

  @doc "Returns the exact worktree-relative evidence references written in checks."
  @spec references(map()) :: [term()]
  def references(checks) do
    checks
    |> Map.values()
    |> Enum.flat_map(fn
      %{"evidence" => paths} when is_list(paths) -> paths
      %{"evidence" => path} -> [path]
      _other -> []
    end)
    |> Enum.uniq()
  end

  @spec walk(String.t(), String.t(), {map(), list(), non_neg_integer()}, non_neg_integer()) ::
          {map(), list(), non_neg_integer()}
  defp walk(root, relative, {files, errors, bytes} = acc, depth) do
    path = Path.join(root, relative)

    if depth > 12 or map_size(files) >= @max_files or bytes >= @max_bytes do
      {files, ["#{relative}: evidence limit exceeded" | errors], bytes}
    else
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> walk_directory(root, relative, acc, depth)
        {:ok, %{type: :regular, size: size}} -> snapshot(path, relative, size, acc)
        {:ok, %{type: type}} -> {files, ["#{relative}: unsupported #{type}" | errors], bytes}
        {:error, :enoent} when relative in [".harness", @root] -> acc
        {:error, reason} -> {files, ["#{relative}: #{reason}" | errors], bytes}
      end
    end
  end

  @spec walk_directory(String.t(), String.t(), tuple(), non_neg_integer()) :: tuple()
  defp walk_directory(root, ".harness", acc, depth), do: walk(root, @root, acc, depth + 1)

  defp walk_directory(root, relative, {files, errors, bytes} = acc, depth) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reduce(acc, &walk(root, Path.join(relative, &1), &2, depth + 1))

      {:error, reason} ->
        {files, ["#{relative}: #{reason}" | errors], bytes}
    end
  end

  @spec snapshot(String.t(), String.t(), non_neg_integer(), tuple()) :: tuple()
  defp snapshot(_path, relative, size, {files, errors, bytes}) when size > @max_file_bytes or size + bytes > @max_bytes do
    {files, ["#{relative}: evidence byte limit exceeded" | errors], bytes}
  end

  defp snapshot(path, relative, _size, {files, errors, bytes}) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      {:ok, content}
      when is_binary(content) and byte_size(content) <= @max_file_bytes and byte_size(content) + bytes <= @max_bytes ->
        file = %{
          "content" => Base.encode64(content),
          "bytes" => byte_size(content),
          "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
          "media_type" => media_type(content)
        }

        {Map.put(files, relative, file), errors, bytes + byte_size(content)}

      {:ok, :eof} ->
        file = %{
          "content" => "",
          "bytes" => 0,
          "sha256" => Base.encode16(:crypto.hash(:sha256, ""), case: :lower),
          "media_type" => "application/octet-stream"
        }

        {Map.put(files, relative, file), errors, bytes}

      {:ok, {:error, reason}} ->
        {files, ["#{relative}: #{reason}" | errors], bytes}

      {:ok, _content} ->
        {files, ["#{relative}: evidence byte limit exceeded" | errors], bytes}

      {:error, reason} ->
        {files, ["#{relative}: #{reason}" | errors], bytes}
    end
  end

  @spec media_type(binary()) :: String.t()
  defp media_type(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>), do: "image/png"
  defp media_type(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"
  defp media_type(_content), do: "application/octet-stream"
end
