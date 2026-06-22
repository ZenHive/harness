defmodule Harness.FacetTest do
  use ExUnit.Case, async: true

  alias Harness.Facet

  doctest Facet

  describe "normalize/1" do
    test "stringifies keys and drops nil values" do
      assert Facet.normalize(%{"scope" => "core", lang: "elixir", area: nil}) ==
               %{"lang" => "elixir", "scope" => "core"}
    end

    test "an empty map normalizes to an empty map" do
      assert Facet.normalize(%{}) == %{}
    end

    test "a non-map normalizes to the empty map" do
      assert Facet.normalize(nil) == %{}
      assert Facet.normalize("not a facet") == %{}
      assert Facet.normalize([:not, :a, :map]) == %{}
    end
  end
end
