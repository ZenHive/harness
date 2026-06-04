defmodule Mix.Tasks.Harness.InstallIncludes do
  @shortdoc "Install harness workflow include into ~/.claude/includes (or --dest)"

  @moduledoc """
  Copies the version-controlled harness workflow include from priv/includes/
  into the user's ~/.claude/includes/ (or a --dest directory). This is the
  delivery mechanism for the promoted `harness-workflow.md` include.

      mix harness.install_includes
      mix harness.install_includes --dest /tmp/test-includes

  If the target file exists and differs, a .bak-<unix> backup is made before
  overwrite (use --force to skip backup). Idempotent when content matches.
  The source is located via :code.priv_dir(:harness) or a dev-tree fallback.

  After install, other repos adopt the harness workflow the normal way:

      @~/.claude/includes/harness-workflow.md

  in their CLAUDE.md (see the include's "Relationship to Other Includes" table
  for layering vs workflow-philosophy.md, task-prioritization.md, etc.).
  """

  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [dest: :string, force: :boolean])
    dest_dir = Keyword.get(opts, :dest) || Path.expand("~/.claude/includes")
    src = locate_source()

    unless File.regular?(src) do
      Mix.raise("harness includes source not found at #{src} (priv/includes/harness-workflow.md missing from this harness install)")
    end

    File.mkdir_p!(dest_dir)
    target = Path.join(dest_dir, "harness-workflow.md")

    action = install_file(src, target, force: Keyword.get(opts, :force, false))
    IO.puts("harness.install_includes: #{action} #{target}")
    :ok
  end

  @spec locate_source() :: String.t()
  defp locate_source do
    # Preferred: the priv that ships with the :harness application (works for
    # hex dep installs and for `iex -S mix` after compile).
    case :code.priv_dir(:harness) do
      {:error, _} ->
        # Dev-tree fallback: task lives at lib/mix/tasks/, priv is three levels up.
        Path.expand("../../../priv/includes/harness-workflow.md", __DIR__)

      priv_dir ->
        Path.join([priv_dir, "includes", "harness-workflow.md"])
    end
    |> Path.expand()
  end

  @spec install_file(String.t(), String.t(), keyword()) :: String.t()
  defp install_file(src, target, opts) do
    content = File.read!(src)

    if File.exists?(target) do
      case File.read(target) do
        {:ok, ^content} ->
          "up-to-date:"

        {:ok, _existing} ->
          if Keyword.get(opts, :force, false) do
            File.cp!(src, target)
            "updated (forced):"
          else
            bak = target <> ".bak-" <> Integer.to_string(System.system_time(:second))
            File.cp!(target, bak)
            File.cp!(src, target)
            "updated (backup #{Path.basename(bak)}):"
          end

        {:error, reason} ->
          # Unreadable target; treat as replaceable.
          File.cp!(src, target)
          "installed (replaced unreadable target #{inspect(reason)}):"
      end
    else
      File.cp!(src, target)
      "installed:"
    end
  end
end
