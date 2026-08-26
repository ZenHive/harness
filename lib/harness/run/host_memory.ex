defmodule Harness.Run.HostMemory do
  @moduledoc false

  @doc "Returns total physical RAM in KiB, or zero when it cannot be determined."
  @spec total_kb() :: non_neg_integer()
  def total_kb do
    case :os.type() do
      {:unix, :darwin} -> sysctl_memsize_kb()
      {:unix, _other} -> meminfo_total_kb()
      _other -> 0
    end
  end

  @spec sysctl_memsize_kb() :: non_neg_integer()
  defp sysctl_memsize_kb do
    with {out, 0} <- System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true),
         {bytes, _rest} <- Integer.parse(String.trim(out)) do
      div(bytes, 1024)
    else
      _other -> 0
    end
  end

  @spec meminfo_total_kb() :: non_neg_integer()
  defp meminfo_total_kb do
    with {:ok, contents} <- File.read("/proc/meminfo"),
         [_line, kb] <- Regex.run(~r/MemTotal:\s+(\d+)/, contents) do
      String.to_integer(kb)
    else
      _other -> 0
    end
  end
end
