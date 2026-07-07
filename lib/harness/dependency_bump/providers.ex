defmodule Harness.DependencyBump.Providers do
  @moduledoc false

  use Harness.LanguageProviders,
    providers: %{
      elixir: Harness.DependencyBump.Provider.Elixir,
      go: Harness.DependencyBump.Provider.Go,
      javascript: Harness.DependencyBump.Provider.JavaScript,
      rust: Harness.DependencyBump.Provider.Rust,
      typescript: Harness.DependencyBump.Provider.JavaScript
    }
end
