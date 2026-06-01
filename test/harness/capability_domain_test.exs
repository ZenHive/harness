defmodule Harness.CapabilityDomainTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Item
  alias Harness.CapabilityDomain

  test "domains/0 includes the Elixir-stack starters and room for other languages" do
    domains = CapabilityDomain.domains()

    assert :otp in domains
    assert :genserver in domains
    assert :liveview in domains
    assert :phoenix in domains
    assert :ecto in domains
    assert :oban in domains
    assert :rust in domains
    assert domains == Enum.sort(domains)
  end

  test "validate/1 accepts atoms and rejects non-atoms" do
    assert {:ok, [:ecto, :otp]} = CapabilityDomain.validate([:otp, :ecto, :otp])
    assert {:error, {:invalid_domain_tag, "otp"}} = CapabilityDomain.validate(["otp"])
  end

  test "buckets/1 maps empty tags to :untagged" do
    assert CapabilityDomain.buckets([]) == [:untagged]
    assert CapabilityDomain.buckets([:liveview, :otp]) == [:liveview, :otp]
  end

  test "Benchmark.Item.build/1 validates and carries domain tags" do
    assert {:ok, item} =
             Item.build(
               id: "bench-1",
               version: 1,
               domains: [:oban, :otp, :oban],
               intent: "Exercise benchmark item validation.",
               acceptance_criteria: ["The item builds"],
               target_project: "harness",
               check_stack: "elixir",
               expected_green: true
             )

    assert item.id == "bench-1"
    assert item.domains == [:oban, :otp]
  end
end
