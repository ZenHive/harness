defmodule Harness.Benchmark.Eval.Ecto.ChangesetNormalizeTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Ecto.ChangesetNormalize

  test "normalizes email" do
    changeset = ChangesetNormalize.changeset(%ChangesetNormalize{}, %{email: "  Ada@Example.COM "})
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :email) == "ada@example.com"
  end

  test "rejects blank and malformed email" do
    blank = ChangesetNormalize.changeset(%ChangesetNormalize{}, %{email: "   "})
    refute blank.valid?

    bad = ChangesetNormalize.changeset(%ChangesetNormalize{}, %{email: "not-an-email"})
    refute bad.valid?
  end
end
