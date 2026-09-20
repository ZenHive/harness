defmodule Harness.Oban.Lifeline do
  @moduledoc """
  Age-based Oban rescue excluding dispatches owned by registered runs.

  Holds suspend run lifetimes, so job age alone cannot establish abandonment.
  The local run registry is the ownership authority, as in boot orphan rescue.
  This assumes one harness runtime per database; it is not a distributed lease.
  Attempt timestamps remain unchanged so Oban's completion fencing still works.
  """

  @behaviour Oban.Plugin

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Oban.Engine
  alias Oban.Job
  alias Oban.Peer
  alias Oban.Period
  alias Oban.Repo

  @default_interval to_timeout(minute: 1)
  @run_worker Oban.Worker.to_string(Harness.Run.Worker)

  @impl Oban.Plugin
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oban.Plugin
  @spec validate(keyword()) :: :ok | {:error, term()}
  defdelegate validate(opts), to: Oban.Lifeline

  @impl Oban.Plugin
  @spec format_logger_output(Oban.Config.t(), map()) :: map()
  defdelegate format_logger_output(conf, meta), to: Oban.Lifeline

  @impl GenServer
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    state = %{
      conf: Keyword.fetch!(opts, :conf),
      interval: Period.to_milliseconds(Keyword.get(opts, :interval, @default_interval)),
      rescue_after: Period.to_milliseconds(Keyword.fetch!(opts, :rescue_after)),
      timer: nil
    }

    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})
    {:ok, schedule(state)}
  end

  @impl GenServer
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info(:rescue, state) do
    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      case rescue_jobs(state) do
        {:ok, extra} -> {:ok, Map.merge(meta, extra)}
        {:error, error} -> {:error, Map.merge(meta, %{rescued_jobs: [], discarded_jobs: [], error: error})}
      end
    end)

    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    :ok
  end

  @spec schedule(map()) :: map()
  defp schedule(state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :rescue, state.interval)}
  end

  @spec rescue_jobs(map()) :: {:ok, map()} | {:error, term()}
  defp rescue_jobs(state) do
    if Peer.leader?(state.conf) do
      Repo.transaction(state.conf, fn -> rescue_owned(state) end, on_exhausted: :log)
    else
      {:ok, %{rescued_jobs: [], discarded_jobs: []}}
    end
  end

  @spec rescue_owned(map()) :: map()
  defp rescue_owned(state) do
    # A failed registry read must abort the tick, never mean "no owners".
    live_ids = RunSupervisor.list_runs()

    query =
      from(job in Job,
        where:
          job.worker != ^@run_worker or is_nil(fragment("?->>'run_id'", job.args)) or
            fragment("?->>'run_id'", job.args) not in ^live_ids
      )

    {:ok, jobs} = Engine.rescue_jobs(state.conf, query, rescue_after: state.rescue_after)
    {rescued, discarded} = Enum.split_with(jobs, &(&1.state == "available"))
    %{rescued_jobs: rescued, discarded_jobs: discarded}
  end
end
