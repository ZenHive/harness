defmodule Harness.Benchmark.Corpus do
  @moduledoc """
  Loader for fixed capability-benchmark corpus files.

  Corpus files live under `priv/benchmarks/*.toml` and use one item per file:

      id = "bench.example"
      version = 1
      domains = ["elixir", "otp"]
      expected_green = true

      [task]
      intent = "Implement the requested behavior."
      acceptance = ["The behavior is covered by tests"]

      [target]
      project = "harness"
      check_stack = "elixir_precommit"

  The TOML reader is intentionally small: it supports the scalar and string-list
  shapes the benchmark schema needs, and rejects unsupported syntax loudly.
  """

  alias Harness.Benchmark.Item

  @corpus_dir Path.expand("../../priv/benchmarks", __DIR__)
  @corpus_paths @corpus_dir |> Path.join("*.toml") |> Path.wildcard() |> Enum.sort()

  for path <- @corpus_paths do
    @external_resource path
  end

  @embedded_sources Enum.map(@corpus_paths, &{&1, File.read!(&1)})

  @typedoc "A benchmark corpus loading or validation error."
  @type error :: {:invalid_item, Path.t(), term()} | {:duplicate_id, String.t()}

  @doc "Loads the embedded benchmark corpus from `priv/benchmarks/*.toml`."
  @spec list() :: [Item.t()]
  def list, do: load_sources!(@embedded_sources)

  @doc "Returns an embedded corpus item by id."
  @spec get(String.t()) :: {:ok, Item.t()} | {:error, {:unknown_benchmark, String.t()}}
  def get(id) when is_binary(id), do: get(list(), id)

  @doc "Returns an item by id from an already-loaded corpus."
  @spec get([Item.t()], String.t()) :: {:ok, Item.t()} | {:error, {:unknown_benchmark, String.t()}}
  def get(items, id) when is_list(items) and is_binary(id) do
    case Enum.find(items, &(&1.id == id)) do
      nil -> {:error, {:unknown_benchmark, id}}
      item -> {:ok, item}
    end
  end

  @doc "Returns an embedded corpus item by id, raising if it is absent."
  @spec get!(String.t()) :: Item.t()
  def get!(id) when is_binary(id), do: get!(list(), id)

  @doc "Returns an item by id from an already-loaded corpus, raising if it is absent."
  @spec get!([Item.t()], String.t()) :: Item.t()
  def get!(items, id) when is_list(items) and is_binary(id) do
    case get(items, id) do
      {:ok, item} -> item
      {:error, reason} -> raise ArgumentError, "unknown benchmark item: #{inspect(reason)}"
    end
  end

  @doc "Filters embedded corpus items by declared capability domain."
  @spec filter_by_domain(atom()) :: [Item.t()]
  def filter_by_domain(domain) when is_atom(domain), do: filter_by_domain(list(), domain)

  @doc "Filters already-loaded corpus items by declared capability domain."
  @spec filter_by_domain([Item.t()], atom()) :: [Item.t()]
  def filter_by_domain(items, domain) when is_list(items) and is_atom(domain) do
    Enum.filter(items, &(domain in &1.domains))
  end

  @doc "Loads every `*.toml` item in a directory, raising on malformed items."
  @spec load_dir!(Path.t()) :: [Item.t()]
  def load_dir!(dir) when is_binary(dir) do
    dir
    |> toml_paths!()
    |> Enum.map(&{&1, read_text!(&1)})
    |> load_sources!()
  end

  @spec toml_paths!(Path.t()) :: [Path.t()]
  defp toml_paths!(dir) do
    root = Path.expand(dir)

    root
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&assert_under_root!(&1, root))
    |> Enum.sort()
  end

  @spec assert_under_root!(Path.t(), Path.t()) :: Path.t()
  defp assert_under_root!(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      path
    else
      raise "invalid benchmark corpus path outside #{root}: #{path}"
    end
  end

  @spec read_text!(Path.t()) :: String.t()
  defp read_text!(path) do
    path
    |> String.to_charlist()
    |> :file.read_file()
    |> case do
      {:ok, body} ->
        IO.iodata_to_binary(body)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @spec load_sources!([{Path.t(), String.t()}]) :: [Item.t()]
  defp load_sources!(sources) do
    sources
    |> Enum.map(fn {path, body} -> parse_source!(path, body) end)
    |> reject_duplicate_ids!()
  end

  @spec reject_duplicate_ids!([Item.t()]) :: [Item.t()]
  defp reject_duplicate_ids!(items) do
    case items |> Enum.map(& &1.id) |> duplicate() do
      nil -> items
      id -> raise "invalid benchmark corpus: duplicate id #{inspect(id)}"
    end
  end

  @spec duplicate([String.t()]) :: String.t() | nil
  defp duplicate(ids), do: Enum.find(ids, &(Enum.count(ids, fn id -> id == &1 end) > 1))

  @spec parse_source!(Path.t(), String.t()) :: Item.t()
  defp parse_source!(path, body) do
    path
    |> parse_toml!(body)
    |> fields_from_document()
    |> Item.build()
    |> case do
      {:ok, item} -> item
      {:error, reason} -> raise "invalid benchmark corpus item #{path}: #{inspect(reason)}"
    end
  rescue
    exception in RuntimeError ->
      reraise exception, __STACKTRACE__
  end

  @spec fields_from_document(map()) :: keyword()
  defp fields_from_document(doc) do
    task = Map.get(doc, "task", %{})
    target = Map.get(doc, "target", %{})

    [
      id: Map.get(doc, "id"),
      version: Map.get(doc, "version"),
      domains: domain_atoms(Map.get(doc, "domains")),
      intent: Map.get(task, "intent"),
      acceptance_criteria: Map.get(task, "acceptance"),
      target_project: Map.get(target, "project"),
      check_stack: Map.get(target, "check_stack"),
      expected_green: Map.get(doc, "expected_green")
    ]
  end

  @spec domain_atoms(term()) :: [atom()] | term()
  defp domain_atoms(domains) when is_list(domains) do
    Enum.map(domains, fn
      domain when is_atom(domain) -> domain
      domain when is_binary(domain) and domain != "" -> existing_domain_atom(domain)
      domain -> domain
    end)
  end

  defp domain_atoms(domains), do: domains

  @spec existing_domain_atom(String.t()) :: atom() | String.t()
  defp existing_domain_atom(domain) do
    String.to_existing_atom(domain)
  rescue
    ArgumentError -> domain
  end

  @spec parse_toml!(Path.t(), String.t()) :: map()
  defp parse_toml!(path, body) do
    body
    |> logical_lines()
    |> Enum.reduce({"", %{}}, fn {line, line_no}, {section, doc} ->
      if section?(line) do
        {section_name!(path, line, line_no), doc}
      else
        {key, value} = key_value!(path, line, line_no)
        {section, put_value(doc, section, key, value)}
      end
    end)
    |> elem(1)
  end

  @spec logical_lines(String.t()) :: [{String.t(), pos_integer()}]
  defp logical_lines(body) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, &collect_logical_line/2)
    |> finish_logical_lines!()
    |> Enum.reverse()
  end

  @spec collect_logical_line({String.t(), pos_integer()}, {list(), nil | {pos_integer(), [String.t()]}}) ::
          {list(), nil | {pos_integer(), [String.t()]}}
  defp collect_logical_line({raw_line, line_no}, {lines, pending}) do
    line = String.trim(raw_line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        {lines, pending}

      pending != nil ->
        {start_line, parts} = pending
        parts = [line | parts]

        if String.ends_with?(line, "]") do
          {[{parts |> Enum.reverse() |> Enum.join(" "), start_line} | lines], nil}
        else
          {lines, {start_line, parts}}
        end

      String.contains?(line, "[") and not String.ends_with?(line, "]") ->
        {lines, {line_no, [line]}}

      true ->
        {[{line, line_no} | lines], nil}
    end
  end

  @spec finish_logical_lines!({list(), nil | {pos_integer(), [String.t()]}}) :: list()
  defp finish_logical_lines!({lines, nil}), do: lines

  defp finish_logical_lines!({_lines, {line_no, _parts}}) do
    raise "invalid TOML near line #{line_no}: unterminated array"
  end

  @spec section?(String.t()) :: boolean()
  defp section?(line), do: String.starts_with?(line, "[") and String.ends_with?(line, "]")

  @spec section_name!(Path.t(), String.t(), pos_integer()) :: String.t()
  defp section_name!(path, line, line_no) do
    name =
      line
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    if name in ["task", "target"] do
      name
    else
      raise "invalid benchmark corpus item #{path}: unsupported section #{inspect(name)} at line #{line_no}"
    end
  end

  @spec key_value!(Path.t(), String.t(), pos_integer()) :: {String.t(), term()}
  defp key_value!(path, line, line_no) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        {String.trim(key), parse_value!(path, String.trim(value), line_no)}

      _ ->
        raise "invalid benchmark corpus item #{path}: expected key/value at line #{line_no}"
    end
  end

  @spec parse_value!(Path.t(), String.t(), pos_integer()) :: term()
  defp parse_value!(path, value, line_no) do
    cond do
      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        parse_string_array!(path, value, line_no)

      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"") |> unescape_string()

      value == "true" ->
        true

      value == "false" ->
        false

      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      true ->
        raise "invalid benchmark corpus item #{path}: unsupported value at line #{line_no}"
    end
  end

  @spec parse_string_array!(Path.t(), String.t(), pos_integer()) :: [String.t()]
  defp parse_string_array!(path, value, line_no) do
    inner =
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    strings =
      ~r/"((?:\\"|[^"])*)"/
      |> Regex.scan(inner, capture: :all_but_first)
      |> Enum.map(fn [string] -> unescape_string(string) end)

    leftovers = Regex.replace(~r/"((?:\\"|[^"])*)"/, inner, "")

    if String.match?(leftovers, ~r/^[\s,]*$/) do
      strings
    else
      raise "invalid benchmark corpus item #{path}: expected string array at line #{line_no}"
    end
  end

  @spec unescape_string(String.t()) :: String.t()
  defp unescape_string(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  @spec put_value(map(), String.t(), String.t(), term()) :: map()
  defp put_value(doc, "", key, value), do: Map.put(doc, key, value)

  defp put_value(doc, section, key, value) do
    Map.update(doc, section, %{key => value}, &Map.put(&1, key, value))
  end
end
