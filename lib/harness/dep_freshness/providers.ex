defmodule Harness.DepFreshness.Providers do
  @moduledoc false

  use Harness.LanguageProviders,
    providers: %{
      elixir: Harness.DepFreshness.Provider.Elixir,
      go: Harness.DepFreshness.Provider.Go,
      javascript: Harness.DepFreshness.Provider.JavaScript,
      rust: Harness.DepFreshness.Provider.Rust,
      typescript: Harness.DepFreshness.Provider.JavaScript
    }
end
