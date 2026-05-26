defmodule Harness.Repo do
  @moduledoc """
  PostgreSQL repository used by Oban-backed dispatch.
  """

  use Ecto.Repo,
    otp_app: :harness,
    adapter: Ecto.Adapters.Postgres
end
