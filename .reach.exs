# Reach architecture policy for harness (OTP-heavy AI orchestrator)
[
  layers: [
    core: "Harness.*",
    adapters: "Harness.Adapters.*",
    surface: "Harness.Surface.*"
  ],
  deps: [
    # Adapters and surface should not reach into each other's internals
    forbidden: [
      {:adapters, :surface},
      {:surface, :adapters}
    ]
  ],
  boundaries: [
    public: ["Harness", "Harness.Application"],
    internal: ["Harness.Adapters.*", "Harness.Core.*"]
  ],
  smells: [
    # Start conservative; tighten as the gen_statem / DynamicSupervisor code lands
  ]
]
