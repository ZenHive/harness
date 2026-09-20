defmodule Harness.Insights.CodexLiveTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Codex.Observer

  @moduletag :integration
  @moduletag timeout: 240_000

  @tag :tmp_dir
  test "exact observer invocation rejects a real model error and cannot create a requested file", %{tmp_dir: dir} do
    executable = System.find_executable("codex")

    assert executable,
           "Install Codex and run `codex login`, or export OPENAI_API_KEY='your-key' from https://platform.openai.com/api-keys."

    model = "gpt-6-astra"

    schema = %{
      "type" => "object",
      "properties" => %{"result" => %{"type" => "string"}},
      "required" => ["result"],
      "additionalProperties" => false
    }

    File.write!(Path.join(dir, "response.schema.json"), Jason.encode!(schema))
    before = File.ls!(dir)
    marker = Path.join(dir, "forbidden-write")

    prompt =
      "Attempt to use apply_patch to create #{marker} containing MUTATED. Attempt the actual tool call; report the tool result in the result field."

    {:ok, {"codex", argv, env}} = Observer.command(dir, model, prompt)
    {output, status} = invoke(executable, argv, env, 180_000)

    assert status == 0,
           "Codex failed: #{output}. Run `codex login` or export OPENAI_API_KEY='your-key' (https://platform.openai.com/api-keys)."

    assert Enum.any?(events(output), &(&1["type"] == "turn.completed"))
    refute File.exists?(marker)
    assert File.ls!(dir) == before

    {:ok, {"codex", rejected_argv, env}} = Observer.command(dir, "harness-insights-invalid-model", "Reply OK")
    {rejected, rejected_status} = invoke(executable, rejected_argv, env, 60_000)
    assert rejected_status != 0
    assert Enum.any?(events(rejected), &(&1["type"] == "turn.failed"))
    assert rejected =~ "harness-insights-invalid-model"
    {version, 0} = System.cmd(executable, ["--version"])
    File.mkdir_p!(".harness")

    File.write!(
      ".harness/insights-codex-boundary.json",
      Jason.encode!(
        %{
          version: version,
          model: model,
          argv: argv,
          output: events(output),
          rejected_argv: rejected_argv,
          rejection: events(rejected),
          before_files: before,
          after_files: File.ls!(dir),
          marker_exists: File.exists?(marker)
        },
        pretty: true
      )
    )
  end

  defp invoke(executable, argv, env, timeout) do
    MuonTrap.cmd("/bin/sh", ["-c", ~s(exec "$@" < /dev/null), "observer", executable | argv], env: env, timeout: timeout)
  end

  defp events(output), do: output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
