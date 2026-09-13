defmodule Harness.Run.TestDbTemplateTest do
  use ExUnit.Case, async: true

  alias Harness.Run.TestDbTemplate

  @recipe %{
    "repo" => "App.Repo",
    "database" => "app_test",
    "template" => "harness_test_template_app_v1",
    "extensions" => ["vector", "postgis"]
  }

  test "only accepts an explicit dedicated test recipe" do
    assert {:ok, nil} = TestDbTemplate.normalize(nil)
    assert {:ok, @recipe} = TestDbTemplate.normalize(@recipe)

    for value <- [false, %{}, "live", %{"repo" => "App.Repo"}] do
      assert {:error, _} = TestDbTemplate.normalize(value)
    end

    for {key, values} <- %{
          "repo" => [nil, "", "repo", "App.Repo;code"],
          "database" => [nil, "app", "app_prod", String.duplicate("x", 32) <> "_test", "app';_test"],
          "template" => [nil, "template0", "template1", "app_prod", String.duplicate("x", 64)],
          "extensions" => [nil, [], [nil], ["bad;name"], "vector"]
        },
        value <- values do
      assert {:error, _} = TestDbTemplate.normalize(Map.put(@recipe, key, value))
    end

    assert {:error, _} = TestDbTemplate.normalize(Map.put(@recipe, "unknown", true))
  end

  test "partition uses the entire run id and stays within PostgreSQL's identifier limit" do
    a = TestDbTemplate.partition("run-1-same")
    b = TestDbTemplate.partition("run-2-same")
    assert a != b
    assert a == TestDbTemplate.partition("run-1-same")
    assert byte_size(a) == 27
    assert a =~ ~r/^_h_[a-f0-9]+$/
    assert byte_size(TestDbTemplate.partition(String.duplicate("x", 1000))) == 27
  end
end
