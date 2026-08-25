defmodule Harness.ToolingBaseline.Manifest do
  @moduledoc """
  Harness-shipped per-language tooling baseline manifests.

  Derived from the vibe_kit + elixir-setup committed bootstrap; read-only facts
  for providers — harness never mutates target projects from here.
  """

  alias Harness.ToolingBaseline.Advisory

  @type t :: %{
          deps: [String.t()],
          aliases: [String.t()],
          config_files: [String.t()],
          advisory: [Advisory.t()]
        }

  @elixir_manifest_path Application.app_dir(:harness, "priv/tooling_baseline/elixir.json")
  @external_resource @elixir_manifest_path

  @doc "Loads the Elixir baseline manifest from priv."
  @spec elixir() :: {:ok, t()} | {:error, term()}
  def elixir do
    load_json(@elixir_manifest_path)
  end

  @spec load_json(String.t()) :: {:ok, t()} | {:error, term()}
  defp load_json(path) do
    with {:ok, content} <- :file.read_file(String.to_charlist(path)),
         {:ok, map} <- Jason.decode(content) do
      {:ok, decode_manifest(map)}
    end
  end

  @spec decode_manifest(map()) :: t()
  defp decode_manifest(%{} = map) do
    %{
      deps: string_list(map, "deps"),
      aliases: string_list(map, "aliases"),
      config_files: string_list(map, "config_files"),
      advisory: advisory_list(map)
    }
  end

  @spec string_list(map(), String.t()) :: [String.t()]
  defp string_list(map, key) do
    map
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  @spec advisory_list(map()) :: [Advisory.t()]
  defp advisory_list(map) do
    map
    |> Map.get("advisory", [])
    |> List.wrap()
    |> Enum.map(&Advisory.from_map/1)
  end
end
