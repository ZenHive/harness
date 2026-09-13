defmodule Harness.Run.MemoryGuardFailureTest do
  use ExUnit.Case, async: false

  alias Harness.Run.MemoryGuard

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("PATH")
    System.put_env("PATH", dir)
    on_exit(fn -> System.put_env("PATH", previous) end)
    :ok
  end

  test "an unavailable ps contributes no RSS" do
    assert MemoryGuard.host_rss_kb() == 0
    assert MemoryGuard.tree_rss_kb(123) == 0
  end

  test "a failed ps does not treat its output as a process table", %{tmp_dir: dir} do
    install_ps(dir, "printf '123 1 456\\n'\nexit 1")
    assert MemoryGuard.host_rss_kb() == 0
    assert MemoryGuard.tree_rss_kb(123) == 0
  end

  test "malformed ps rows are ignored while valid descendants are counted", %{tmp_dir: dir} do
    install_ps(dir, "printf 'bad row\\n123 1 100\\n124 123 200\\n125 123 invalid\\n'")
    assert MemoryGuard.host_rss_kb() == 300
    assert MemoryGuard.tree_rss_kb(123) == 300
  end

  defp install_ps(dir, script) do
    path = Path.join(dir, "ps")
    File.write!(path, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(path, 0o755)
  end
end
