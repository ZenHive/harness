defmodule Harness.Maintenance.Command do
  @moduledoc "Bounded subprocess ownership with private output capture."

  @doc "Captures output in an exclusive private file, avoiding fast-exit port acknowledgement races."
  # The path contains only the OS temporary directory and a generated UUID. Arguments remain argv.
  # sobelow_skip ["Traversal.FileModule"]
  @spec run(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer() | atom()}
  def run(command, args, opts) do
    path = Path.join(System.tmp_dir!(), "maintenance-output-#{Ecto.UUID.generate()}")
    File.open!(path, [:write, :exclusive], fn _file -> File.chmod!(path, 0o600) end)

    try do
      {_, status} = MuonTrap.cmd("/bin/sh", ["-c", ~s(exec "$@" > "$0" 2>&1), path, command | args], opts)
      {File.read!(path), status}
    after
      File.rm(path)
    end
  end
end
