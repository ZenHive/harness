defmodule Harness.CapabilityDomainTest do
  use ExUnit.Case, async: true

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
    assert :javascript in domains
    assert :typescript in domains
    assert domains == Enum.sort(domains)
  end

  test "normalize/1 atomizes curated strings and preserves unknown tags as strings" do
    tags = ["javascript", "typescript", "delta_calc", :custom_stack]

    assert CapabilityDomain.normalize(tags) == [:javascript, :typescript, "custom_stack", "delta_calc"]
    assert CapabilityDomain.buckets(tags) == [:javascript, :typescript, "custom_stack", "delta_calc"]
    assert CapabilityDomain.known?(:otp)
    assert CapabilityDomain.known?("otp")
    refute CapabilityDomain.known?("delta_calc")
    refute CapabilityDomain.known?(:delta_calc)
  end

  test "validate/1 accepts atom and string tags and rejects other values" do
    assert {:ok, [:ecto, :otp]} = CapabilityDomain.validate([:otp, :ecto, :otp])
    assert {:ok, [:otp, "unknown"]} = CapabilityDomain.validate(["otp", "unknown"])
    assert {:error, {:invalid_domain_tag, 42}} = CapabilityDomain.validate([42])
  end

  test "buckets/1 maps empty tags to :untagged" do
    assert CapabilityDomain.buckets([]) == [:untagged]
    assert CapabilityDomain.buckets([:liveview, :otp]) == [:liveview, :otp]
  end
end
