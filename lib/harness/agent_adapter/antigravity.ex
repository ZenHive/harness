defmodule Harness.AgentAdapter.Antigravity do
  @moduledoc """
  The headless adapter for the Antigravity CLI (`agy`) — driven via `agy` over an OTP port.

  Like every adapter it is thin: all the real logic is `build_command/1` assembling
  the headless command line. Raw output is captured and passed through unparsed;
  termination is detected from the port closing, never from the exit code.

  ## Invocation

  Runs `agy -p "<prompt>"` for headless execution.

  ## Working directory / workspace

  `agy` does **not** honor the port `:cd` alone for file writes (Task 32, Task
  198): it resolves workspace via git metadata and can edit the main checkout
  while the run worktree stays clean. Isolation is pinned on two channels, like
  Codex's `--cd` fix (Task 41): the port `:cd` **and** `--add-dir <worktree>`
  in `build_command/1`. `--add-dir` is the load-bearing flag — `agy` exposes no
  `--cwd` / `--workspace` replacement, only this repeatable workspace add.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` maps to Antigravity's
  `--dangerously-skip-permissions` flag to bypass permissions during autonomous execution.
  Only `:autonomous` permission mode is supported.

  ## Session resume

  Resuming uses `--continue` for session resumption. The `Invocation` `session`
  field therefore carries the `:resume` sentinel, not a literal token; any other
  non-`nil` value is an error.

  ## Model override

  `agy` 1.0.10+ accepts `--model <id>` (see `AgentAdapter.model_args/1`). Harness
  validates every non-nil pin against `@verified_catalog` **before** spawning —
  `agy --model` itself is non-validating and silently falls back to the CLI default
  on unknown ids, which would violate harness's no-silent-default contract.

  ### Verified `agy --model` ids (2026-06-21, agy 1.0.10)

  Positively confirmed — not by absence of `--model` error (unknown ids are silently
  accepted), but via the shipped binary's settings schema default (`gemini-3.5-flash`),
  `fetchAvailableModels` label propagation (`Gemini 3.5 Flash (Medium)` →
  `gemini-3.5-flash`), and task-scoped live CLI verification documented in Task 322.
  Display labels from `agy models` carry reasoning suffixes `(Low)` / `(Medium)` /
  `(High)` / `(Thinking)` that are **not** part of the id.

  | Display label (`agy models`) | `--model` id |
  | --- | --- |
  | Gemini 3.5 Flash (Low/Medium/High) | `gemini-3.5-flash` |
  | Gemini 3.1 Pro (Low/High) | `gemini-3.1-pro` |
  | Claude Sonnet 4.6 (Thinking) | `claude-sonnet-4-5` |
  | Claude Opus 4.6 (Thinking) | `claude-opus-4-5` |
  | GPT-OSS 120B | `gpt-oss-120b` |
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @permission_modes %{autonomous: "--dangerously-skip-permissions"}

  # Display labels from `agy models` → dash-form ids accepted by `agy --model`.
  # Reasoning-level suffixes in the label are not part of the id.
  @verified_catalog [
    %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Low)"},
    %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Medium)"},
    %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (High)"},
    %{id: "gemini-3.1-pro", label: "Gemini 3.1 Pro (Low)"},
    %{id: "gemini-3.1-pro", label: "Gemini 3.1 Pro (High)"},
    %{id: "claude-sonnet-4-5", label: "Claude Sonnet 4.6 (Thinking)"},
    %{id: "claude-opus-4-5", label: "Claude Opus 4.6 (Thinking)"},
    %{id: "gpt-oss-120b", label: "GPT-OSS 120B"}
  ]

  @known_model_ids @verified_catalog |> Enum.map(& &1.id) |> MapSet.new()

  @display_label_to_id Map.new(@verified_catalog, &{&1.label, &1.id})

  @doc false
  @spec known_model_ids() :: [String.t()]
  def known_model_ids, do: MapSet.to_list(@known_model_ids)

  @doc false
  @spec catalog_entries() :: [map()]
  def catalog_entries, do: @verified_catalog

  @doc false
  @spec display_label_to_id(String.t()) :: String.t() | nil
  def display_label_to_id(label) when is_binary(label), do: Map.get(@display_label_to_id, String.trim(label))

  @doc """
  Declares Antigravity's capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    # Intentionally no `auth_env_scrub`: official Antigravity CLI auth docs
    # describe secure-keyring, browser, and SSH OAuth flows with no API-key env
    # var; local `agy` help/strings do not verify `GEMINI_API_KEY` or
    # `GOOGLE_API_KEY` as CLI auth overrides.
    # Source: https://antigravity.google/docs/cli-install
    %Capabilities{
      session_resume: true,
      permission_modes: [:autonomous],
      streaming_output: true,
      worktree_isolation: true,
      model_families: [:google, :anthropic, :openai]
    }
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :prompt_preamble

  @doc """
  Builds the `agy` headless command line for `invocation`.

  Returns `{:error, {:invalid_model_for_adapter, __MODULE__, model}}` when the
  pinned model is absent from the verified catalog, `{:error, {:unsupported_permission_mode, mode}}`
  for a permission mode outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume`.
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         :ok <- validate_catalog_model(invocation.model),
         {:ok, permission} <- AgentAdapter.permission_flag(@permission_modes, invocation.permission_mode),
         {:ok, resume} <- AgentAdapter.resume_args(invocation.session) do
      argv =
        ["--add-dir", invocation.cwd, permission] ++
          AgentAdapter.model_args(invocation.model) ++
          resume ++
          ["-p", AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"agy", argv, env}}
    end
  end

  @spec validate_catalog_model(String.t() | nil) :: :ok | {:error, {:invalid_model_for_adapter, module(), String.t()}}
  defp validate_catalog_model(nil), do: :ok

  defp validate_catalog_model(model) when is_binary(model) do
    if MapSet.member?(@known_model_ids, model) do
      :ok
    else
      {:error, {:invalid_model_for_adapter, __MODULE__, model}}
    end
  end
end
