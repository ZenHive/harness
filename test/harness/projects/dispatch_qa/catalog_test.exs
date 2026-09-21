defmodule Harness.Projects.DispatchQA.CatalogTest do
  use ExUnit.Case, async: true

  alias Harness.Projects.DispatchQA.Catalog

  @names [
    "aave_sim",
    "blockwatch",
    "bourse",
    "bourse_trading",
    "ccxt-distill",
    "delta_calc",
    "harness",
    "harness_agent_adapter",
    "mpp",
    "onchain_stack",
    "rmap",
    "starconiq",
    "tapakly",
    "trading_dashboard",
    "zen_quant",
    "zen_websocket"
  ]

  test "inventories all 16 registered projects with exact before/after mappings" do
    entries = Catalog.all()

    assert Enum.map(entries, & &1.name) == @names
    assert Enum.all?(entries, &(&1.write_set != []))
  end

  test "bourse_trading QA does not depend on the alias being slimmed" do
    entry = Catalog.entry("bourse_trading")
    refute entry.qa =~ "check.dispatch"
    assert entry.qa =~ "precommit.full"
    assert entry.qa =~ "ex_dna --max-clones 0"
    assert entry.qa =~ "reach.check --arch --dead-code --smells"
  end

  test "aave_sim drops mandatory Dialyzer from dispatch and keeps it in QA" do
    entry = Catalog.entry("aave_sim")

    assert entry.before_check_command =~ "mix dialyzer.json"
    refute entry.dispatch =~ "dialyzer"
    assert entry.qa == "mix precommit.full"
    refute Catalog.requires_qa_pass?(entry)
  end

  test "onchain_stack dispatch stays per-package while QA covers the whole project" do
    entry = Catalog.entry("onchain_stack")

    refute entry.dispatch == entry.before_check_command
    assert entry.dispatch =~ "packages/<name>"
    assert entry.qa == "mix ci"
    refute Catalog.requires_qa_pass?(entry)
    assert "packages/hieroglyph/mix.exs" in entry.write_set
    assert "packages/onchain_tempo/AGENTS.md" in entry.write_set
  end

  test "Rust and TypeScript use native commands" do
    rmap = Catalog.entry("rmap")
    distill = Catalog.entry("ccxt-distill")

    assert rmap.dispatch =~ "cargo fmt"
    assert rmap.dispatch =~ "cargo check --all-targets"
    refute rmap.dispatch =~ "clippy"
    assert rmap.qa =~ "cargo clippy --all-targets -- -D warnings"
    refute rmap.dispatch =~ "&& cargo test"
    assert rmap.qa =~ "cargo test"
    refute Catalog.requires_qa_pass?(rmap)

    assert distill.before_check_command == "npm run check"
    assert distill.dispatch =~ "npm run typecheck"
    assert distill.qa == "npm run check"
    refute Catalog.requires_qa_pass?(distill)
  end

  test "Elixir projects use explicit focused commands and record a full QA command" do
    for name <- ~w(harness blockwatch bourse tapakly) do
      entry = Catalog.entry(name)
      assert entry.before_check_command == "mix check.dispatch"
      assert entry.dispatch =~ "mix format --check-formatted"
      assert String.starts_with?(entry.qa, ["mix precommit.full", "mix ci"])
      refute Catalog.requires_qa_pass?(entry)
    end
  end
end
