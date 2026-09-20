defmodule Harness.Dispatch.ContractTest do
  use ExUnit.Case, async: true

  alias Harness.Dispatch
  alias Harness.Manifest

  # Captured from the public facade before Task 359's structural extraction.
  # Fingerprints include descriptions, schemas, defaults, parameter order and specs.
  # MCP required-property lists are sets; sort their existing unstable order.
  @functions [
    __api__: 0,
    __api__: 1,
    approve: 1,
    approve: 2,
    assess_facets: 0,
    assess_facets: 1,
    await: 2,
    await: 3,
    await: 4,
    await: 5,
    await_result: 2,
    await_runs: 1,
    await_runs: 2,
    bundle: 1,
    bundle: 2,
    bundle: 3,
    cancel: 1,
    coalesce: 2,
    coalesce: 3,
    coalesce: 4,
    compare: 3,
    compare: 4,
    compare: 5,
    hold: 1,
    hold: 2,
    pending: 0,
    pending: 1,
    qa_evidence: 1,
    qa_evidence: 2,
    qa_evidence: 3,
    qa_status: 1,
    qa_status: 2,
    recommend: 1,
    recommend: 2,
    recommended_adapter_for_item: 2,
    recommended_adapter_for_item: 3,
    register_project: 5,
    register_project: 6,
    register_project: 7,
    register_project: 8,
    register_project: 9,
    register_project: 10,
    reland: 1,
    rereview: 1,
    rereview_opts: 3,
    resume: 1,
    resume_adapter: 2,
    resume_failed: 1,
    resume_failed: 2,
    resume_item: 2,
    resume_opts: 2,
    run_start_opts: 3,
    start_opts: 2,
    status: 1,
    steer: 2,
    summarize_comparison: 1,
    summarize_oban_job_status: 1,
    summarize_result: 1,
    summarize_verdict_detail: 1,
    task: 2,
    task: 3,
    task: 4,
    tooling_baseline: 1,
    tooling_baseline: 2,
    tooling_baseline: 3,
    tooling_baseline: 4,
    transcript: 1,
    transcript_events: 1,
    update_deps: 1,
    update_deps: 2,
    update_deps: 3,
    update_deps: 4,
    verdict_detail: 1
  ]

  test "preserves every public function and default arity" do
    assert Dispatch.__info__(:functions) == @functions
  end

  test "comparison overloads forward both model maps and scrub flags" do
    for args <- [
          ["project", "next", []],
          ["project", "next", [], false],
          ["project", "next", [], %{"codex" => "model"}],
          ["project", "next", [], %{}, true]
        ] do
      assert {:error, :no_adapters} = apply(Dispatch, :compare, args)
    end

    assert_raise FunctionClauseError, fn -> Dispatch.compare("project", "next", [], :invalid) end
  end

  test "preserves descripex declarations and the dispatch manifest" do
    assert fingerprint(Dispatch.__api__()) == "fa1bd13754a303fbefd0c26707628918dee27cd905cab542431d02aac7594af6"

    manifest = Manifest.build().modules |> Enum.find(&(&1.namespace == "/dispatch")) |> normalize_manifest()
    assert fingerprint(manifest) == "1cb442aaf412724706fc3aa90a5d818b200a55a7d8e76aefb12eb2acd63c7e49"
  end

  test "preserves generated MCP tools and keeps implementation modules off the driver surface" do
    tools =
      Manifest.mcp_tools()
      |> Enum.filter(&String.starts_with?(&1.name, "dispatch-"))
      |> Enum.map(fn tool -> update_in(tool.inputSchema.required, &Enum.sort/1) end)

    assert fingerprint(tools) == "fa3c0f99c0eecbc6b8039fa69feeeac250306f4fa6a0bc840c9be2eb3c059f71"

    assert Enum.filter(Manifest.modules(), &(&1 |> Module.split() |> Enum.member?("Dispatch"))) == [Dispatch]
  end

  # Descripex embeds inspected maps in docs; BEAM map iteration order can vary
  # across compilations. Compare their parsed contents while retaining all prose.
  @spec normalize_manifest(map()) :: map()
  defp normalize_manifest(manifest) do
    update_in(manifest.functions, &Enum.map(&1, fn function -> normalize_function(function) end))
  end

  @spec normalize_function(map()) :: map()
  defp normalize_function(function) do
    update_in(function.description, &normalize_description/1)
  end

  @spec normalize_description(String.t()) :: String.t()
  defp normalize_description(description) do
    Regex.replace(~r/```elixir\n# descripex:contract\n(.*?)\n```/s, description, &normalize_contract/2)
  end

  @spec normalize_contract(String.t(), String.t()) :: String.t()
  defp normalize_contract(_block, code) do
    code
    |> Code.string_to_quoted!()
    |> Macro.postwalk(fn
      {:%{}, _, fields} -> {:%{}, [], Enum.sort(fields)}
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
    |> Macro.to_string()
  end

  @spec fingerprint(term()) :: String.t()
  defp fingerprint(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
