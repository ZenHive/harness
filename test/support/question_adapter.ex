defmodule Harness.Test.QuestionAdapter do
  @moduledoc false

  # Implementer double that writes `.harness/question.json` (or a malformed
  # stand-in) and, on session resume, records the injected prompt.

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.Run.Question

  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan], model_families: []}
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :none

  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{env: env, adapter_opts: opts} = invocation) do
    command = Keyword.get(opts, :command, :question)
    {exe, argv} = command_argv(command, invocation)
    {:ok, {exe, argv, Map.to_list(env)}}
  end

  @spec command_argv(atom(), Invocation.t()) :: {String.t(), [String.t()]}
  defp command_argv(:malformed, _invocation) do
    script = ~S(mkdir -p .harness; echo '{not json' > .harness/question.json; echo agent-output > agent_output.txt)
    {"/bin/sh", ["-c", script]}
  end

  defp command_argv(:empty, %Invocation{env: env}) do
    json = question_json(env, "   ")
    script = ~S(mkdir -p .harness; printf '%s' "$1" > .harness/question.json; echo agent-output > agent_output.txt)
    {"/bin/sh", ["-c", script, "harness-fake", json]}
  end

  defp command_argv(:stale_identity, %Invocation{env: env}) do
    json =
      env
      |> question_fields("should not park")
      |> Map.put("run_id", "other-run")
      |> Jason.encode!()

    script = ~S(mkdir -p .harness; printf '%s' "$1" > .harness/question.json; echo agent-output > agent_output.txt)
    {"/bin/sh", ["-c", script, "harness-fake", json]}
  end

  defp command_argv(:question_twice, %Invocation{adapter_opts: opts} = invocation) do
    case bump(opts) do
      1 -> write_question(invocation.env, "first question")
      2 -> write_question(invocation.env, "second question")
      _other -> write_resume(invocation.prompt)
    end
  end

  defp command_argv(:question_then_sleep, %Invocation{session: :resume}), do: {"/bin/sleep", ["30"]}
  defp command_argv(:question_then_sleep, %Invocation{env: env}), do: write_question(env, "need a decision")

  defp command_argv(_command, %Invocation{session: :resume, prompt: prompt}), do: write_resume(prompt)
  defp command_argv(_command, %Invocation{env: env}), do: write_question(env, "which API shape?", "optional context")

  @spec bump(keyword()) :: pos_integer()
  defp bump(opts) do
    case Keyword.get(opts, :counter) do
      pid when is_pid(pid) -> Agent.get_and_update(pid, fn count -> {count + 1, count + 1} end)
      _absent -> 1
    end
  end

  @spec write_question(map(), String.t(), String.t() | nil) :: {String.t(), [String.t()]}
  defp write_question(env, question, context \\ nil) do
    json = question_json(env, question, context)
    script = ~S(mkdir -p .harness; printf '%s' "$1" > .harness/question.json)
    {"/bin/sh", ["-c", script, "harness-fake", json]}
  end

  @spec write_resume(String.t()) :: {String.t(), [String.t()]}
  defp write_resume(prompt) do
    script = ~S(echo agent-output > agent_output.txt; printf '%s' "$1" > question_resume_prompt.txt)
    {"/bin/sh", ["-c", script, "harness-fake", prompt]}
  end

  @spec question_json(map(), String.t(), String.t() | nil) :: String.t()
  defp question_json(env, question, context \\ nil) do
    env
    |> question_fields(question, context)
    |> Jason.encode!()
  end

  @spec question_fields(map(), String.t(), String.t() | nil) :: map()
  defp question_fields(env, question, context \\ nil) do
    fields = %{
      "question" => question,
      "run_id" => env_get(env, Question.run_id_env()),
      "invocation" => env_get(env, Question.invocation_env())
    }

    if is_binary(context) and context != "", do: Map.put(fields, "context", context), else: fields
  end

  @spec env_get(map(), String.t()) :: String.t()
  defp env_get(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end
end
