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

  test "normalize/1 keeps JS/TS domains through the rmap String.to_existing_atom round-trip" do
    # Harness.Roadmap.task_domains/1 resolves rmap `domains` strings via
    # String.to_existing_atom/1, then normalizes. JS/TS atoms must be registered
    # (by @general_domains) so they survive instead of collapsing to :untagged.
    tags = Enum.map(["javascript", "typescript"], &String.to_existing_atom/1)

    assert CapabilityDomain.normalize(tags) == [:javascript, :typescript]
    assert CapabilityDomain.buckets(tags) == [:javascript, :typescript]
  end

  test "validate/1 accepts atoms and rejects non-atoms" do
    assert {:ok, [:ecto, :otp]} = CapabilityDomain.validate([:otp, :ecto, :otp])
    assert {:error, {:invalid_domain_tag, "otp"}} = CapabilityDomain.validate(["otp"])
  end

  test "buckets/1 maps empty tags to :untagged" do
    assert CapabilityDomain.buckets([]) == [:untagged]
    assert CapabilityDomain.buckets([:liveview, :otp]) == [:liveview, :otp]
  end
end
