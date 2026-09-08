# Optional recipe restore command for classic OTP PLTs. Executed by the target
# project's Elixir/OTP, outside the harness BEAM. OTP owns decoding and encoding.
# Contract: OTP-29.0.5 lib/dialyzer/src/{dialyzer_cplt.erl,dialyzer.hrl};
# Dialyxir.Plt compares absolute filenames before adding/removing modules.
# https://github.com/erlang/otp/blob/OTP-29.0.5/lib/dialyzer/src/dialyzer_cplt.erl

source = "HARNESS_CACHE_SOURCE" |> System.fetch_env!() |> Path.expand()
target = "HARNESS_CACHE_TARGET" |> System.fetch_env!() |> Path.expand()

for path <- System.argv(), File.regular?(path) do
  {plt, {:plt_info, files, dependencies}} = :dialyzer_cplt.plt_and_info_from_file(String.to_charlist(path))

  relocated =
    Enum.map(files, fn {file, digest} ->
      original = List.to_string(file)

      if String.starts_with?(original, source <> "/") do
        relative = Path.relative_to(original, source)
        # Check bytes in the staged copy, or preserved agent state if that path
        # was not copied. A mismatch must leave the normal cold check to rebuild.
        staged = if File.regular?(relative), do: relative, else: Path.join(target, relative)
        [{_file, ^digest}] = :dialyzer_cplt.compute_md5_from_files([String.to_charlist(staged)])
        {String.to_charlist(Path.join(target, relative)), digest}
      else
        {file, digest}
      end
    end)

  :ok = :dialyzer_cplt.to_file(String.to_charlist(path), plt, :dict.new(), {:plt_info, relocated, dependencies})
end
