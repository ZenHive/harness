defmodule Mix.Tasks.Harness.Deps.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Harness.Deps.Check

  @moduletag :tmp_dir

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "warns without failing for an undocumented narrow dep constraint", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mix.exs")
    File.write!(path, ~s({:plug, "~> 1.19.2"}))

    assert :ok = Check.run([path])
    assert_received {:mix_shell, :info, [output]}

    assert output =~ "warning: narrow dependency constraints found (advisory)"
    assert output =~ path
    assert output =~ "~> 1.19.2"
  end

  test "accepts a justified over-tight dep constraint", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mix.exs")
    File.write!(path, ~s({:plug, "~> 1.19.2"} # tight pin: 1.20 changed parser behavior))

    assert :ok = Check.run([path])
    refute_received {:mix_shell, :info, _}
  end

  test "still fails when the dependency file cannot be read", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing.exs")

    assert_raise Mix.Error, ~r/could not read .*missing.exs/, fn ->
      Check.run([path])
    end
  end
end
