defmodule Harness.Benchmark.CorpusContentTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Corpus
  alias Harness.Benchmark.Item
  alias Harness.CapabilityDomain

  @expected_ids [
    "bench.otp.latch",
    "bench.otp.supervised_counter",
    "bench.genserver.accumulator",
    "bench.liveview.tally",
    "bench.liveview.form_validate",
    "bench.oban.reverse",
    "bench.oban.attempt_echo",
    "bench.ecto.embedded_profile",
    "bench.ecto.changeset_normalize",
    "bench.elixir.tree_walk",
    "bench.elixir.pipeline"
  ]

  describe "embedded priv/benchmarks corpus" do
    test "loads all curated items with expected_green" do
      items = Corpus.list()
      ids = items |> Enum.map(& &1.id) |> Enum.sort()

      assert length(items) == length(@expected_ids)
      assert ids == Enum.sort(@expected_ids)
      assert Enum.all?(items, &(&1.expected_green == true))
      assert Enum.all?(items, &(&1.target_project == "harness"))
      assert Enum.all?(items, &(&1.check_stack == "elixir"))
    end

    test "spans OTP, GenServer, LiveView, Oban, Ecto, and plain Elixir domains" do
      items = Corpus.list()

      assert Enum.any?(items, &(:otp in &1.domains))
      assert Enum.any?(items, &(:genserver in &1.domains))
      assert Enum.any?(items, &(:liveview in &1.domains))
      assert Enum.any?(items, &(:phoenix in &1.domains))
      assert Enum.any?(items, &(:oban in &1.domains))
      assert Enum.any?(items, &(:ecto in &1.domains))
      assert Enum.any?(items, &(:elixir in &1.domains))

      assert Enum.count(items, &(:otp in &1.domains)) >= 2
      assert Enum.count(items, &(:liveview in &1.domains)) >= 2
      assert Enum.count(items, &(:oban in &1.domains)) >= 2
      assert Enum.count(items, &(:ecto in &1.domains)) >= 2
      assert Enum.count(items, &(:elixir in &1.domains)) >= 2
    end

    test "every domain tag is a known capability domain" do
      for %Item{domains: domains} <- Corpus.list(), domain <- domains do
        assert CapabilityDomain.known?(domain)
      end
    end

    test "load_dir!/1 reads the shipped priv/benchmarks tree" do
      dir = Path.expand("../../../priv/benchmarks", __DIR__)
      assert length(Corpus.load_dir!(dir)) == length(@expected_ids)
    end

    test "filter_by_domain returns matching corpus items" do
      assert [%Item{id: "bench.oban.attempt_echo"}, %Item{id: "bench.oban.reverse"}] =
               :oban |> Corpus.filter_by_domain() |> Enum.sort_by(& &1.id)
    end
  end
end
