defmodule Harness.Maintenance.FilesTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Maintenance.Files

  test "tracked content is paged without following symlinks or escaping the checkout" do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, "large.txt"), String.duplicate("a", 24_001))
    File.ln_s!("/etc/passwd", Path.join(repo, "link"))
    GitFixture.git!(repo, ["add", "large.txt", "link"])
    assert {:ok, inventory} = Files.inventory(repo)
    assert {:ok, %{"text" => first, "next_offset" => 24_000}} = Files.read(repo, inventory, "large.txt", 0)
    assert byte_size(first) == 24_000
    assert {:ok, %{"text" => "a", "next_offset" => nil}} = Files.read(repo, inventory, "large.txt", 24_000)
    assert {:ok, %{"text" => "", "next_offset" => nil}} = Files.read(repo, inventory, "large.txt", 24_001)
    assert {:error, :unavailable_path} = Files.read(repo, inventory, "link", 0)
    assert {:error, :unavailable_path} = Files.read(repo, ["../secret"], "../secret", 0)
    assert {:error, :unavailable_path} = Files.read(repo, ["/etc/passwd"], "/etc/passwd", 0)
    assert {:error, :unavailable_path} = Files.read(repo, inventory, "untracked", 0)
    assert {:error, :invalid_read} = Files.read(repo, inventory, "README.md", -1)
  end

  test "binary and absent evidence cannot be confused with an empty file" do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, "binary"), <<255, 254>>)
    GitFixture.git!(repo, ["add", "binary"])
    assert {:ok, inventory} = Files.inventory(repo)
    assert {:error, :binary_file} = Files.read(repo, inventory, "binary", 0)
    File.rm!(Path.join(repo, "binary"))
    assert {:error, :unavailable_path} = Files.read(repo, inventory, "binary", 0)
    assert {:error, :inventory_unavailable} = Files.inventory(Path.join(repo, "missing"))
  end
end
