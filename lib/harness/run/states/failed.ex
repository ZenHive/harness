defmodule Harness.Run.States.Failed do
  @moduledoc false

  import Harness.Run.Actions, only: [handle_common: 4]
  import Harness.Run.Actions.Settlement, only: [settle: 2]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2]

  @typep data :: map()
  @typep event :: term()
  @typep handler_result :: term()

  @doc false
  @spec handle(event(), term(), data()) :: handler_result()
  def handle(:enter, _old_state, data) do
    data = stamp_state_entry(:failed, data)
    data = settle(data, :failed)
    {:keep_state, data, [{:state_timeout, data.terminal_linger, :shutdown}]}
  end

  def handle(:state_timeout, :shutdown, data), do: {:stop, :normal, data}

  def handle(event_type, event_content, data) do
    handle_common(event_type, event_content, :failed, data)
  end
end
