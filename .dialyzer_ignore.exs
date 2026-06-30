# See https://github.com/jeremyjh/dialyxir#elixir-ignores
# Add {:error, :bad_return, ...} style tuples or regexes as needed.
[
  # describe_reason/1 is a total function spec'd over term(): its final
  # catch-all clause defensively handles reason shapes deserialized from older
  # persisted records, which success-typing cannot see. Dialyzer flags the
  # clause as unreachable (pattern_match_cov); the runtime safety is intentional.
  # Pre-existing since c6d0eb2 (perf/idiom sweep).
  {"lib/harness/status_view.ex", :pattern_match_cov}
]
