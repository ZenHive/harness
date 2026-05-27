# Used by "mix format"
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view],
  inputs: [
    "{mix,.formatter,.credo,.doctor,.dialyzer_ignore,.reach}.exs",
    "{config,lib,test}/**/*.{ex,exs,heex}"
  ],
  plugins: [Styler, Phoenix.LiveView.HTMLFormatter]
]
