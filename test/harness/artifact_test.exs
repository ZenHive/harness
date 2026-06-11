defmodule Harness.ArtifactTest do
  use ExUnit.Case, async: true

  alias Harness.Artifact

  describe "read/2" do
    @tag :tmp_dir
    test "returns the contents of an existing artifact", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".harness"))
      File.write!(Path.join(tmp_dir, ".harness/review.json"), ~s({"verdict": "approve"}))

      assert Artifact.read(tmp_dir, ".harness/review.json") == {:ok, ~s({"verdict": "approve"})}
    end

    @tag :tmp_dir
    test "returns :missing when the artifact was never written", %{tmp_dir: tmp_dir} do
      assert Artifact.read(tmp_dir, ".harness/review.json") == {:error, :missing}
    end

    @tag :tmp_dir
    test "returns an unreadable error when the path is not a regular file", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".harness/review.json"))

      assert Artifact.read(tmp_dir, ".harness/review.json") ==
               {:error, {:malformed, {:unreadable, :eisdir}}}
    end
  end
end
