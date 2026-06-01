defmodule Tiny.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [{:jason, "~> 1.4"}]
  end
end
