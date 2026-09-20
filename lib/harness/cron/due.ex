defmodule Harness.Cron.Due do
  @moduledoc "Due-date checks for scheduled passes."

  @doc "Checks whether an ISO 8601 timestamp has arrived; invalid values are not due."
  @spec due?(term()) :: boolean()
  def due?(next) when is_binary(next) do
    case DateTime.from_iso8601(next) do
      {:ok, date, _} -> DateTime.compare(date, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  def due?(_), do: false
end
