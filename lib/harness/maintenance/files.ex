defmodule Harness.Maintenance.Files do
  @moduledoc "Bounded read-only retrieval from an isolated checkout, with no agent shell authority."

  @doc "Returns the tracked-file inventory without interpreting repository content."
  @spec inventory(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def inventory(root) do
    case Harness.Git.run(["ls-files", "-z"], root) do
      {:ok, output} -> {:ok, String.split(output, <<0>>, trim: true)}
      _ -> {:error, :inventory_unavailable}
    end
  end

  @doc "Reads a tracked regular file; symlink components and traversal are refused."
  @spec read(String.t(), [String.t()], String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def read(root, inventory, path, offset) when is_binary(path) and is_integer(offset) and offset >= 0 do
    if path in inventory and safe?(root, path) do
      with {:ok, file} <- :file.open(String.to_charlist(Path.join(root, path)), [:read, :binary]) do
        try do
          decode(:file.pread(file, offset, 24_000), path, offset)
        after
          :file.close(file)
        end
      end
    else
      {:error, :unavailable_path}
    end
  end

  def read(_, _, _, _), do: {:error, :invalid_read}

  @spec decode(term(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  defp decode({:ok, bytes}, path, offset) do
    if String.valid?(bytes),
      do:
        {:ok,
         %{
           "path" => path,
           "offset" => offset,
           "text" => bytes,
           "next_offset" => if(byte_size(bytes) == 24_000, do: offset + byte_size(bytes))
         }},
      else: {:error, :binary_file}
  end

  defp decode(:eof, path, offset), do: {:ok, %{"path" => path, "offset" => offset, "text" => "", "next_offset" => nil}}
  defp decode(_, _, _), do: {:error, :file_unavailable}

  @spec safe?(String.t(), String.t()) :: boolean()
  defp safe?(root, path) do
    parts = Path.split(path)

    Path.type(path) == :relative and ".." not in parts and
      Enum.reduce_while(parts, root, fn part, parent ->
        next = Path.join(parent, part)

        case File.lstat(next) do
          {:ok, %{type: type}} when type in [:regular, :directory] -> {:cont, next}
          _ -> {:halt, false}
        end
      end) != false
  end
end
