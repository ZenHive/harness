defmodule Harness.Benchmark.Eval.Ecto.EmbeddedProfileTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Ecto.EmbeddedProfile

  test "valid profile changeset" do
    changeset = EmbeddedProfile.changeset(%EmbeddedProfile{}, %{name: "Ada", age: 30})
    assert changeset.valid?
  end

  test "rejects missing name and out-of-range age" do
    changeset = EmbeddedProfile.changeset(%EmbeddedProfile{}, %{name: "", age: 200})
    refute changeset.valid?
    assert {"can't be blank", _} = Keyword.get(changeset.errors, :name)
    assert {"must be less than or equal to %{number}", _} = Keyword.get(changeset.errors, :age)
  end
end
