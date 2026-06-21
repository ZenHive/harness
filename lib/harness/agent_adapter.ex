defmodule Harness.AgentAdapter do
  @moduledoc """
  The contract every headless coding-agent adapter implements.

  An adapter is deliberately thin: it builds an agent's headless command line,
  spawns it over an OTP port, classifies the port's messages as raw output /
  termination / failure, and can kill an in-flight run. It does **not** parse or
  normalize the agent's output — harness passes raw transcripts through
  untouched (the consumer is an AI that reads them natively) and derives run
  success from its own verification stack, never from the agent's exit code or
  self-reported result.

  ## Implementing an adapter

  An adapter `use`s `Harness.AgentAdapter` (which declares the `@behaviour`) and
  implements the three required callbacks; `classify_message/2` and `terminate/1`
  have defaults (universal port classification and kill) and need only be
  overridden for agent-specific logic:

      defmodule MyAgent.Adapter do
        use Harness.AgentAdapter
        alias Harness.AgentAdapter.Capabilities
        alias Harness.AgentAdapter.Invocation

        @impl true
        def capabilities, do: %Capabilities{session_resume: true}

        @impl true
        def rule_channel, do: :prompt_preamble

        @impl true
        def build_command(%Invocation{rules: rules} = invocation) do
          prompt = rules.prompt || invocation.prompt
          {:ok, {"my-agent", ["-p", prompt], Map.to_list(invocation.env)}}
        end
      end

  Harness spawns the adapter with `invoke/2` — there is no per-adapter
  invocation boilerplate. `invoke/2` attaches harness-owned rules (via
  `c:rule_channel/0`) before calling `c:build_command/1`.

  ## Run lifecycle

  `invoke/2` attaches harness-owned rules (via `c:rule_channel/0`), builds the
  command via the adapter's `c:build_command/1`, and spawns the agent, returning
  a `Harness.AgentAdapter.Run`. The process that calls
  `invoke/2` becomes the port's connected process, so every subsequent port
  message is delivered to *it* — that process feeds each message through the
  adapter's `c:classify_message/2`, which is how raw output is captured and
  termination detected. A run ends when `classify_message/2` returns
  `:terminated` (the agent process closed) or `:error` (the port itself failed).
  `Harness.AgentAdapter.Driver` is the generic implementation of that drive
  loop — it adds raw-output accumulation and the total-run / idle timeout
  guards on top of `invoke/2` + `c:classify_message/2`.

  ## Deliberate deferrals

    * **Session-token extraction (resolved).** Resuming needs no dedicated
      token-extraction callback. The Claude Code adapter resumes the most recent
      conversation in `cwd` via `--continue`; because each harness job owns one
      worktree, "the latest session in `cwd`" is unambiguous. The
      `Harness.AgentAdapter.Invocation` `session` field stays an opaque
      pass-through value each adapter interprets as it needs.
    * **Availability probe.** A `version/0` / "is the binary installed" callback
      is anticipated for the capability + availability registry and will be
      added then as an optional callback.
  """

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.RuleDelivery
  alias Harness.AgentAdapter.RulesInjection
  alias Harness.AgentAdapter.Run

  # The shell and script every agent is spawned through — see spawn_run/5 for
  # why a headless agent CLI cannot be handed a raw OTP-port stdin.
  @sh "/bin/sh"
  @stdin_eof_script ~S(exec "$0" "$@" </dev/null)
  @codex_agents_rel "AGENTS.md"
  @cursor_rules_rel ".cursor/rules/harness-operational.mdc"
  @system_prompt_file_flags ["--append-system-prompt-file", "--system-prompt-file"]
  @model_family_prefixes %{
    anthropic: ["anthropic/claude-", "claude-", "opus", "sonnet", "haiku"],
    cursor: ["composer-"],
    google: ["gemini-"],
    kimi: ["kimi-"],
    openai: ["chatgpt-", "codex-", "gpt-", "gpt-oss-", "o1", "o3", "o4", "o5"],
    xai: ["grok-", "xai/"]
  }

  @doc false
  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour Harness.AgentAdapter

      @impl true
      def classify_message(message, run), do: Harness.AgentAdapter.classify_message(message, run)

      @impl true
      def terminate(run), do: Harness.AgentAdapter.terminate(run)

      defoverridable classify_message: 2, terminate: 1
    end
  end

  @typedoc """
  A built headless command: the executable, its argv, and environment pairs.
  The env list carries caller (and adapter) overrides: `{key, value}` sets,
  `{key, false}` unsets an inherited variable.
  """
  @type command ::
          {executable :: String.t(), argv :: [String.t()], env :: [{String.t(), String.t() | false}]}

  @typedoc "A rule file captured as part of one agent dispatch input."
  @type rule_file :: %{
          required(:path) => String.t(),
          required(:content) => String.t() | nil,
          optional(:error) => term()
        }

  @typedoc """
  The prompt/rule artifact actually handed to an adapter for one dispatch.

  `argv` is included because some adapters deliver the prompt as a positional
  value while others use a flag; `rule_files` carries the bytes read after the
  ephemeral files are written and before cleanup can remove them.
  """
  @type composed_input :: %{
          required(:executable) => String.t(),
          required(:argv) => [String.t()],
          required(:rule_channel) => rule_channel(),
          required(:prompt) => String.t(),
          required(:session) => term() | nil,
          required(:rule_files) => [rule_file()],
          optional(:attempt) => non_neg_integer(),
          optional(:phase) => :initial | :steer
        }

  @typedoc """
  The result of classifying one process message against a run.

    * `{:output, iodata, run}` — a chunk of the agent's raw output, verbatim.
    * `{:terminated, run, exit_status}` — the agent process closed. `exit_status`
      is advisory only and must never decide run success.
    * `{:error, reason, run}` — an infrastructure failure: the port itself
      failed, or the run could not execute. Distinct from `:terminated` so a
      retry policy can tell a broken run from a finished one.
    * `:ignore` — the message does not belong to this run.
  """
  @type classification ::
          {:output, iodata(), Run.t()}
          | {:terminated, Run.t(), exit_status :: integer() | nil}
          | {:error, reason :: term(), Run.t()}
          | :ignore

  @typedoc "A capability that `supports?/2` can be queried for."
  @type capability ::
          :session_resume
          | :streaming_output
          | :worktree_isolation
          | {:permission_mode, atom()}
          | {:cost_tier, Capabilities.cost_tier()}

  @doc """
  Declares what the agent's headless mode can do. Static — independent of any
  one run.
  """
  @callback capabilities() :: Capabilities.t()

  @typedoc """
  How harness-owned rules reach the agent at dispatch time.

    * `:system_prompt_file` — ephemeral file plus argv flags (Claude).
    * `:codex_ephemeral_file` — ephemeral `AGENTS.md` in the worktree.
    * `:cursor_ephemeral_file` — ephemeral `.cursor/rules/` file in the worktree.
    * `:prompt_preamble` — rules prepended to the task prompt (Grok, Antigravity).
    * `:none` — test doubles only; no rule injection.
  """
  @type rule_channel() ::
          :system_prompt_file
          | :codex_ephemeral_file
          | :cursor_ephemeral_file
          | :prompt_preamble
          | :none

  @doc """
  Declares how harness-owned rules are delivered for this agent.
  """
  @callback rule_channel() :: rule_channel()

  @doc """
  Builds the headless command line for invoking the agent.

  Pure — computes the executable, argv, and environment without spawning
  anything. Kept separate from `invoke/2` so it can be unit-tested directly.
  """
  @callback build_command(Invocation.t()) :: {:ok, command()} | {:error, term()}

  @doc """
  Classifies one process message received by the run's driving process.

  This is how raw output is captured — `{:output, iodata, run}` carries the
  agent's bytes untouched — and how termination is detected, from the port
  closing rather than the exit code.
  """
  @callback classify_message(message :: term(), Run.t()) :: classification()

  @doc """
  Kills an in-flight run: terminates the agent's OS process and releases its
  port. Must be idempotent — safe to call on a run that has already ended.
  """
  @callback terminate(Run.t()) :: :ok

  # Default implementations for the two universal callbacks. Adapters `use
  # Harness.AgentAdapter` inherit these via the forwarding def + defoverridable;
  # they only implement capabilities/0, rule_channel/0, and build_command/1 unless
  # they need custom classification or termination logic.
  @doc "Default implementation (port data → raw output, exit_status → terminated)."
  @spec classify_message(term(), Run.t()) :: classification()
  def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}
  def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}
  def classify_message(_message, _run), do: :ignore

  @doc "Default implementation: delegates to `OSProcess.kill/1` (idempotent)."
  @spec terminate(Run.t()) :: :ok
  def terminate(%Run{} = run), do: OSProcess.kill(run)

  @doc """
  Attaches harness-owned rules to `invocation` per the adapter's `c:rule_channel/0`.

  Idempotent — a second call on an invocation that already carries `%RuleDelivery{}`
  is a no-op. Called by `invoke/2` before `c:build_command/1`; adapters may also
  call it at the top of `build_command/1` so direct unit tests exercise the same
  path as a live run.
  """
  @spec attach_rules(module(), Invocation.t()) :: {:ok, Invocation.t()} | {:error, term()}
  def attach_rules(_adapter, %Invocation{rules: %RuleDelivery{}} = invocation), do: {:ok, invocation}

  def attach_rules(adapter, %Invocation{} = invocation) do
    case prepare_rule_delivery(adapter.rule_channel(), invocation) do
      {:ok, delivery} -> {:ok, %{invocation | rules: delivery}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the task prompt after rule delivery — `rules.prompt` when the channel
  prepends a preamble, otherwise the original `invocation.prompt`.
  """
  @spec task_prompt(Invocation.t()) :: String.t()
  def task_prompt(%Invocation{rules: %RuleDelivery{prompt: prompt}}) when is_binary(prompt), do: prompt

  def task_prompt(%Invocation{prompt: prompt}), do: prompt

  @doc """
  Captures the composed prompt/rule artifact for an already-built dispatch.
  """
  @spec composed_input(module(), Invocation.t(), command()) :: composed_input()
  def composed_input(adapter, %Invocation{} = invocation, {executable, argv, _env}) do
    %{
      executable: executable,
      argv: argv,
      rule_channel: adapter.rule_channel(),
      prompt: task_prompt(invocation),
      session: invocation.session,
      rule_files: rule_files(adapter.rule_channel(), invocation)
    }
  end

  @doc """
  Spawns `adapter` for an invocation and returns a run handle.

  Builds the command with the adapter's `c:build_command/1`, spawns it over a
  port, and returns a populated `Harness.AgentAdapter.Run`. Must be called from
  the process that will drive the run: the spawned port is connected to the
  caller, so every later port message is delivered there.
  """
  @spec invoke(module(), Invocation.t()) :: {:ok, Run.t()} | {:error, term()}
  def invoke(adapter, %Invocation{} = invocation) do
    with :ok <- validate_model(adapter, invocation.model),
         {:ok, invocation} <- attach_rules(adapter, invocation),
         {:ok, {executable, argv, env} = command} <- adapter.build_command(invocation) do
      input = composed_input(adapter, invocation, command)
      spawn_run(adapter, invocation, executable, argv, scrub_auth_env(adapter, env), input)
    end
  end

  @doc """
  Unsets the adapter's `c:Harness.AgentAdapter.Capabilities.t/0`
  `auth_env_scrub` keys in `env` so the spawned CLI bills the operator's
  subscription, not a stray provider API key.

  Harness spawns each agent CLI as a Port that inherits the BEAM's environment.
  When a provider API key is present (`ANTHROPIC_API_KEY` for `claude`,
  `OPENAI_API_KEY` for `codex`), the CLI silently prefers API billing over the
  interactive subscription login — and a key with an empty balance fails the run
  outright ("Credit balance is too low"). Drops any caller-set value for a
  scrubbed key, then appends `{key, false}` for each — so the key is *always*
  unset in the Port env regardless of what the inherited environment or
  `Invocation.env` carried. A no-op for adapters that declare no scrub. Applied
  by `invoke/2`; public so the scrub is unit-testable without spawning a CLI.
  """
  @spec scrub_auth_env(module(), [{String.t(), String.t() | false}]) :: [{String.t(), String.t() | false}]
  def scrub_auth_env(adapter, env) do
    scrub = adapter.capabilities().auth_env_scrub
    kept = Enum.reject(env, fn {key, _value} -> key in scrub end)
    kept ++ Enum.map(scrub, &{&1, false})
  end

  @doc """
  Returns whether `adapter` supports `capability`, reading the adapter's
  `c:capabilities/0` declaration.
  """
  @spec supports?(module(), capability()) :: boolean()
  def supports?(adapter, capability), do: capability_supported?(adapter.capabilities(), capability)

  @doc """
  Returns whether `adapter` can run `model`.

  A `nil` (unpinned) model is accepted **only** for adapters that declare no
  model selection (`Capabilities.model_families: []`). For every model-capable
  adapter a `nil` is
  rejected — harness never lets a real agent fall through to its CLI's ambient
  default, the guard against a sticky premium default silently burning the token
  budget on every later run. Non-nil pins are checked against the adapter's
  declared `model_families` using family prefixes maintained in this module, not
  per-release literal model IDs.
  """
  @spec model_supported?(module(), String.t() | nil) :: boolean()
  def model_supported?(adapter, nil), do: not model_capable?(adapter)

  def model_supported?(adapter, model) when is_binary(model) do
    model_supported_by_families?(adapter.capabilities().model_families, String.downcase(model))
  end

  @doc """
  Returns whether `adapter` requires an explicitly resolved model.

  `true` for every model-capable adapter (declares `model_families: :any` or a
  non-empty list); `false` only for adapters that declare `model_families: []`.
  The dispatch and reviewer fail-fast
  checks read this to reject a `nil` model before a run starts.
  """
  @spec requires_model?(module()) :: boolean()
  def requires_model?(adapter), do: model_capable?(adapter)

  @doc """
  Returns `["--model", model]` when `model` is a binary, `[]` otherwise.

  Shared argv helper for any adapter whose headless CLI accepts `--model`.
  """
  @spec model_args(String.t() | nil) :: [String.t()]
  def model_args(nil), do: []
  def model_args(model) when is_binary(model), do: ["--model", model]

  @doc """
  Looks up a permission `mode` in the adapter's `modes` map.

  Returns the raw stored value — adapters keep their own argv shape (string
  flag, list of flags) and the helper stays agnostic.
  """
  @spec permission_flag(map(), atom()) ::
          {:ok, term()} | {:error, {:unsupported_permission_mode, atom()}}
  def permission_flag(modes, mode) when is_map(modes) do
    case Map.fetch(modes, mode) do
      {:ok, flag} -> {:ok, flag}
      :error -> {:error, {:unsupported_permission_mode, mode}}
    end
  end

  @doc """
  Validates a permission `mode` against an adapter's `supported` list.

  For adapters whose CLI takes no per-mode flag (Codex, Pi): the mode gates
  `c:build_command/1` without contributing argv — use `permission_flag/2` when
  the mode maps to a flag instead.
  """
  @spec check_permission_mode(atom(), [atom()]) ::
          :ok | {:error, {:unsupported_permission_mode, atom()}}
  def check_permission_mode(mode, supported) when is_list(supported) do
    if mode in supported, do: :ok, else: {:error, {:unsupported_permission_mode, mode}}
  end

  @doc """
  Resolves the session token into argv for adapters whose headless CLI uses
  `--continue` to resume the most recent conversation in `cwd`.

  Shared across every adapter whose resume semantics match Claude's (Claude,
  Cursor, Grok, Antigravity, Pi). Codex resumes by session-id and has its own
  shape.
  """
  @spec resume_args(term()) ::
          {:ok, [String.t()]} | {:error, {:unsupported_session_token, term()}}
  def resume_args(nil), do: {:ok, []}
  def resume_args(:resume), do: {:ok, ["--continue"]}
  def resume_args(other), do: {:error, {:unsupported_session_token, other}}

  # Spawns the agent over an OTP port and returns its run handle.
  #
  # The agent is not spawned directly. It goes through
  # `/bin/sh -c 'exec "$0" "$@" </dev/null' <agent> <argv…>`. An OTP port leaves
  # the spawned process's stdin an open, empty pipe, and a headless agent CLI
  # that peeks stdin — to support `cat prompt.txt | agent -p` — stalls on input
  # that never arrives (`claude` prints "no stdin data received in 3s" and then
  # bails without doing the task). Redirecting the exec'd process's stdin from
  # `/dev/null` hands it an immediate EOF, so it proceeds at once.
  #
  # `exec` replaces the shell in place — the port's OS pid is the agent itself,
  # never a surviving `sh` parent, so `os_pid` and `terminate/1` still reach it.
  # The real executable and argv ride as positional parameters (`$0`, `$@`), so
  # no argument is ever exposed to shell word-splitting, globbing, or expansion —
  # the agent prompt can carry any bytes. `System.find_executable/1` still runs
  # first: it keeps the clean `{:error, {:executable_not_found, _}}` signal and
  # resolves the absolute path `exec` runs regardless of the shell's own PATH.
  #
  # `:stderr_to_stdout` folds the agent's stderr into the captured stream —
  # diagnostics, auth errors, and partial-failure context all reach the consumer
  # rather than leaking to the BEAM's own stderr. Raw passthrough means the AI
  # reading the transcript tolerates interleaved stderr; losing it would not.
  @spec spawn_run(
          module(),
          Invocation.t(),
          String.t(),
          [String.t()],
          [{String.t(), String.t() | false}],
          composed_input()
        ) ::
          {:ok, Run.t()} | {:error, term()}
  defp spawn_run(adapter, invocation, executable, argv, env, composed_input) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        port =
          Port.open({:spawn_executable, @sh}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            {:args, ["-c", @stdin_eof_script, path | argv]},
            {:cd, invocation.cwd},
            {:env, port_env(env)}
          ])

        {:ok,
         %Run{
           ref: make_ref(),
           adapter: adapter,
           port: port,
           os_pid: OSProcess.os_pid(port),
           started_at: System.monotonic_time(),
           composed_input: composed_input
         }}
    end
  end

  @spec rule_files(rule_channel(), Invocation.t()) :: [rule_file()]
  defp rule_files(:system_prompt_file, invocation) do
    invocation
    |> system_prompt_file_paths()
    |> Enum.map(&read_rule_file/1)
  end

  defp rule_files(:codex_ephemeral_file, %Invocation{cwd: cwd}) do
    [read_rule_file(Path.join(cwd, @codex_agents_rel))]
  end

  defp rule_files(:cursor_ephemeral_file, %Invocation{cwd: cwd}) do
    [read_rule_file(Path.join(cwd, @cursor_rules_rel))]
  end

  defp rule_files(:prompt_preamble, _invocation), do: []
  defp rule_files(:none, _invocation), do: []

  @spec system_prompt_file_paths(Invocation.t()) :: [String.t()]
  defp system_prompt_file_paths(%Invocation{rules: %RuleDelivery{argv_flags: flags}}) do
    flags
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _path] -> flag in @system_prompt_file_flags end)
    |> Enum.map(fn [_flag, path] -> path end)
  end

  defp system_prompt_file_paths(_invocation), do: []

  # Diagnostic capture of a harness-owned rule-delivery path (written by
  # attach_rules/2), not external input; a read miss is recorded, never fatal.
  # sobelow_skip ["Traversal.FileModule"]
  @spec read_rule_file(String.t()) :: rule_file()
  defp read_rule_file(path) do
    case File.read(path) do
      {:ok, content} -> %{path: path, content: content}
      {:error, reason} -> %{path: path, content: nil, error: reason}
    end
  end

  @spec port_env([{String.t(), String.t() | false}]) :: [{charlist(), charlist() | false}]
  defp port_env(env) do
    Enum.map(env, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  @spec capability_supported?(Capabilities.t(), capability()) :: boolean()
  defp capability_supported?(%Capabilities{session_resume: value}, :session_resume), do: value
  defp capability_supported?(%Capabilities{streaming_output: value}, :streaming_output), do: value

  defp capability_supported?(%Capabilities{worktree_isolation: value}, :worktree_isolation), do: value

  defp capability_supported?(%Capabilities{permission_modes: modes}, {:permission_mode, mode}), do: mode in modes

  defp capability_supported?(%Capabilities{cost_tier: tier}, {:cost_tier, tier}), do: true
  defp capability_supported?(%Capabilities{}, {:cost_tier, _other}), do: false

  @spec validate_model(module(), String.t() | nil) ::
          :ok
          | {:error, {:model_required, module()}}
          | {:error, {:invalid_model_for_adapter, module(), String.t()}}
  defp validate_model(adapter, nil) do
    if model_capable?(adapter), do: {:error, {:model_required, adapter}}, else: :ok
  end

  defp validate_model(adapter, model) when is_binary(model) do
    if model_supported?(adapter, model) do
      :ok
    else
      {:error, {:invalid_model_for_adapter, adapter, model}}
    end
  end

  # Model-capable iff the adapter declares it can run at least one model family
  # (`:any` or a non-empty list). `[]` means no `--model` flag — the single case
  # where a nil model is legitimate.
  @spec model_capable?(module()) :: boolean()
  defp model_capable?(adapter), do: adapter.capabilities().model_families != []

  @spec model_supported_by_families?(Capabilities.model_families(), String.t()) :: boolean()
  defp model_supported_by_families?(:any, _model), do: true

  defp model_supported_by_families?(families, model) when is_list(families) do
    Enum.any?(families, &model_supported_by_family?(&1, model))
  end

  @spec model_supported_by_family?(Capabilities.model_family(), String.t()) :: boolean()
  defp model_supported_by_family?(family, model) do
    family
    |> model_family_prefixes()
    |> Enum.any?(&String.starts_with?(model, &1))
  end

  @spec model_family_prefixes(Capabilities.model_family()) :: [String.t()]
  defp model_family_prefixes(family), do: Map.fetch!(@model_family_prefixes, family)

  @spec prepare_rule_delivery(rule_channel(), Invocation.t()) ::
          {:ok, RuleDelivery.t()} | {:error, term()}
  defp prepare_rule_delivery(:none, _invocation), do: {:ok, %RuleDelivery{}}

  defp prepare_rule_delivery(:system_prompt_file, invocation) do
    case RulesInjection.claude_flags(invocation) do
      {:ok, flags} -> {:ok, %RuleDelivery{argv_flags: flags}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_rule_delivery(:codex_ephemeral_file, invocation) do
    case RulesInjection.install_codex_rules(invocation) do
      :ok -> {:ok, %RuleDelivery{}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_rule_delivery(:cursor_ephemeral_file, invocation) do
    case RulesInjection.install_cursor_rules(invocation) do
      :ok -> {:ok, %RuleDelivery{}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_rule_delivery(:prompt_preamble, invocation) do
    {:ok, %RuleDelivery{prompt: RulesInjection.prepend_prompt(invocation.prompt, invocation)}}
  end
end
