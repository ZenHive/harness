defmodule Harness.Benchmark.CorpusTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Corpus
  alias Harness.Benchmark.Item

  @valid_dir Path.expand("../../fixtures/benchmark_corpus/valid", __DIR__)
  @malformed_dir Path.expand("../../fixtures/benchmark_corpus/malformed", __DIR__)

  describe "load_dir!/1" do
    test "loads valid benchmark TOML files into item structs" do
      assert [%Item{}, %Item{}] = items = Corpus.load_dir!(@valid_dir)

      assert %Item{
               id: "bench.elixir.loader",
               version: 1,
               domains: [:elixir, :otp],
               intent: "Add a small loader for a fixed corpus.",
               acceptance_criteria: [
                 "The item is fetchable by id",
                 "The item declares Elixir and OTP domains"
               ],
               target_project: "harness",
               check_stack: "elixir",
               expected_green: true
             } = Corpus.get!(items, "bench.elixir.loader")
    end

    test "filters loaded items by domain" do
      items = Corpus.load_dir!(@valid_dir)

      assert [%Item{id: "bench.elixir.loader"}] = Corpus.filter_by_domain(items, :otp)
      assert [%Item{id: "bench.liveview.filter"}] = Corpus.filter_by_domain(items, :liveview)
      assert [] = Corpus.filter_by_domain(items, :oban)
    end

    test "rejects malformed items loudly" do
      assert_raise RuntimeError, ~r/invalid benchmark corpus item.*missing-version\.toml.*version/s, fn ->
        Corpus.load_dir!(@malformed_dir)
      end
    end
  end
end
