defmodule ProjectHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :project_harness,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [mod: {ProjectHarness.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:harness, "~> 0.1"},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.11", only: :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
