defmodule Mix.Tasks.Harness.InstallIncludes do
  @shortdoc "Install harness includes into ~/.claude/includes (or --dest)"

  @moduledoc """
  Copies the version-controlled harness includes from priv/includes/ into the
  user's ~/.claude/includes/ (or a --dest directory): `harness-guardrails.md`
  (the eager always-on floor) and `harness-workflow.md` (the full contract,
  also shipped as the `harness:harness-workflow` skill).

      mix harness.install_includes
      mix harness.install_includes --dest /tmp/test-includes

  For each file: if the target exists and differs, a .bak-<unix> backup is made before
  overwrite (use --force to skip backup). Idempotent when content matches.
  The source is located via `Application.app_dir/2`.

  After install, repos that dispatch through harness import only the guardrails:

      @~/.claude/includes/harness-guardrails.md

  in their CLAUDE.md; the full workflow loads on demand as a skill.
  """

  use Mix.Task

  @includes ~w(harness-guardrails.md harness-workflow.md)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [dest: :string, force: :boolean])
    dest_dir = Keyword.get(opts, :dest) || Path.expand("~/.claude/includes")
    File.mkdir_p!(dest_dir)

    Enum.each(@includes, fn name ->
      src = Application.app_dir(:harness, Path.join("priv/includes", name))

      if !File.regular?(src) do
        Mix.raise("harness includes source not found at #{src} (priv/includes/#{name} missing from this harness install)")
      end

      target = Path.join(dest_dir, name)
      action = install_file(src, target, force: Keyword.get(opts, :force, false))
      IO.puts("harness.install_includes: #{action} #{target}")
    end)
  end

  @spec install_file(String.t(), String.t(), keyword()) :: String.t()
  defp install_file(src, target, opts) do
    content = File.read!(src)

    if File.exists?(target) do
      action_for_existing(src, target, content, opts)
    else
      copy_fresh(src, target, "installed:")
    end
  end

  @spec action_for_existing(String.t(), String.t(), String.t(), keyword()) :: String.t()
  defp action_for_existing(src, target, content, opts) do
    case File.read(target) do
      {:ok, ^content} ->
        "up-to-date:"

      {:error, reason} ->
        copy_fresh(src, target, "installed (replaced unreadable target #{inspect(reason)}):")

      {:ok, _} ->
        overwrite_existing(src, target, opts)
    end
  end

  @spec overwrite_existing(String.t(), String.t(), keyword()) :: String.t()
  defp overwrite_existing(src, target, opts) do
    if Keyword.get(opts, :force, false) do
      copy_fresh(src, target, "updated (forced):")
    else
      overwrite_with_backup(src, target)
    end
  end

  @spec copy_fresh(String.t(), String.t(), String.t()) :: String.t()
  defp copy_fresh(src, target, prefix) do
    File.cp!(src, target)
    prefix
  end

  @spec overwrite_with_backup(String.t(), String.t()) :: String.t()
  defp overwrite_with_backup(src, target) do
    bak = target <> ".bak-" <> Integer.to_string(System.system_time(:second))
    File.cp!(target, bak)
    File.cp!(src, target)
    "updated (backup #{Path.basename(bak)}):"
  end
end
