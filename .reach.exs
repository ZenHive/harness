# Reach architecture policy for harness (OTP-native agent-gate orchestrator)
#
# harness is hub-and-spoke (AgentAdapter behaviour ↔ core run lifecycle ↔
# cold-path dashboard), not a layered architecture — a `layers:`/`deps:` policy
# would report layer cycles that exist by design. The real invariants are
# expressed as forbidden-call rules + public-facade boundaries instead.
[
  calls: [
    forbidden: [
      # The cold-path dashboard never drives agent adapters directly — all
      # dispatch goes through Harness.Dispatch / Harness.Batch.
      {"Harness.Dashboard.*", ["Harness.AgentAdapter.*"]},
      # Adapters are leaves invoked by the run lifecycle — they never reach
      # into the dashboard surface or the Oban dispatch / landing layer.
      {"Harness.AgentAdapter.*",
       [
         "Harness.Dashboard.*",
         "Harness.Dispatch.*",
         "Harness.Batch.*",
         "Harness.Oban.*",
         "Harness.Lander.*"
       ]}
    ]
  ],
  boundaries: [
    # Modules legitimately driven from outside the Harness namespace (Mix
    # tasks, IEx consumers, mounting Phoenix apps): the descripex
    # api()-annotated driver surface plus the persistence/result structs it
    # exchanges.
    public: [
      "Harness",
      "Harness.Application",
      "Harness.AgentAdapter.Driver",
      "Harness.AgentKPI",
      "Harness.AuditReview",
      "Harness.Batch",
      "Harness.Batch.*",
      "Harness.Dispatch",
      "Harness.Dispatch.*",
      "Harness.Manifest",
      "Harness.Playbooks",
      "Harness.ProjectRegistry",
      "Harness.ResultStore",
      "Harness.ResultStore.*",
      "Harness.Roadmap",
      "Harness.Roadmap.*",
      "Harness.Run",
      "Harness.Run.*",
      "Harness.StatusView",
      # Dev/CI tooling: mix harness.deps.check reads mix.exs constraint pins.
      "Harness.DependencyConstraintGuard",
      # The dashboard's template-facing render surface: heex layouts/templates
      # (lowered by Reach's HEEx plugin to Reach.Templates.* pseudo-modules)
      # legitimately render through these. Not external driver API — internal
      # render entry points called across the template boundary.
      "Harness.Dashboard.Components",
      "Harness.Dashboard.Tokens"
    ]
  ],
  smells: [
    # Start conservative; tighten as new smell checks prove signal on this codebase.
  ]
]
