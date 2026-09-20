# Task 447 live audit protocol evidence

On 2026-09-20, `Harness.AuditLiveTest` invoked the real Claude adapter with
`claude-sonnet-5` against two disposable Git repositories. No doubles were used.
The agent executed the supplied shell checks and wrote `.harness/audit.json`.
The test independently asserted the command, revision, outcome, evidence marker,
and unchanged repository HEAD.

The live fixture commands originally used `printf '...\\n'`. An independent
reviewer re-run of `Audit.run/1` recorded a genuine failed check as `incomplete`
because the agent wrote a JSON newline while the configured command stored the
two-character `\n` sequence. The fixtures now use `printf audit-live-success`
and `printf audit-live-failure; exit 17` so the exact-command assertion is
unambiguous. Historical reports below retain the original commands.

Command:

```sh
HARNESS_LIVE_AUDITOR_MODEL=claude-sonnet-5 mix test.json test/harness/audit_live_test.exs --include live_agent --no-retry --output /tmp/audit-live.json
```

Result: 1 test passed, 0 failed; both success and deliberate failure were observed.
This establishes the report protocol, not durable worker lifecycle verification.
The reviewer must independently run the completed integration checks.

An earlier invocation failed because the report included a `sh -c` wrapper in
its command field. The prompt now supplies the exact JSON value to copy; the
assertion remains exact.

Observed reports:

```text
LIVE AUDIT claude-sonnet-5 82ae085bff5de35377fc812e763d716853374f2c: {"qa":{"command":"printf 'audit-live-success\\n'","evidence":"stdout: 'audit-live-success' (single line); exit status: 0","report":"Repository is a minimal single-commit fixture (README.md + .git). Working tree is clean aside from the untracked .harness/ directory used for this audit's own output. The specified full-project check ran verbatim via sh -c and produced the expected literal output 'audit-live-success' with a successful exit code, confirming the command executes correctly against this revision with no missing prerequisites.","revision":"82ae085bff5de35377fc812e763d716853374f2c","status":"passed"}}
LIVE AUDIT claude-sonnet-5 3b28600e4d4847c7524357a3e1e92eaa51d81bb6: {"qa":{"command":"printf 'audit-live-failure\\n'; exit 17","evidence":"stdout: \"audit-live-failure\\n\"; exit status: 17 (non-zero)","report":"Repo at 3b28600e4d4847c7524357a3e1e92eaa51d81bb6 is a minimal fixture: README.md ('harness git fixture'), one commit ('init'), and an empty .harness/agent-rules.md. No build tooling, dependency manifests, CI config, or license present, so no other hygiene checks apply beyond the mandated full-project check. That check, run verbatim via sh -c as instructed and left unmodified, printed 'audit-live-failure' to stdout and exited with status 17, a non-zero (failing) exit code. Per protocol this is judged a failure — command output was produced as expected, but the exit code marks the full-project check as failed for this revision.","revision":"3b28600e4d4847c7524357a3e1e92eaa51d81bb6","status":"failed"}}
```

## Integrated audit lifecycle

The real `Harness.Audit.run/1` lifecycle also passed on 2026-09-20 using
`claude-sonnet-5`. Both runs used detached worktrees of disposable repositories
and a dedicated migrated database, `harness_qa_447_run1789895287799`.
The test asserted persisted project, full revision, configured command,
agent/model, included commit count, outcome and retrievable evidence. Normal
ExUnit sandbox rollback removes the test rows after assertions; the observations
below retain the evidence for review. A separate integration test commits a
pending record, restarts the Repo process, and verifies its pending base survives.

```sh
env -u HARNESS_DATABASE_URL -u DATABASE_URL \
  HARNESS_DB_NAME=harness_qa_447_run1789895287799 \
  HARNESS_LIVE_AUDITOR_MODEL=claude-sonnet-5 \
  mix test.json test/harness/audit/qa_live_test.exs \
  --include live_agent --no-retry --quiet --output /tmp/qa-live.json
```

Result: 1 test passed, 0 failed; both real audit invocations completed. An earlier
lifecycle run failed because its two invocations exceeded the sandbox's default
120-second ownership timeout. The live test now sets a 360-second ownership
limit; no production timeout or check setting changed.

```json
{
  "attempt": {
    "command": "printf 'audit-live-success\\n'",
    "id": "c1086ebb-e50f-4fff-b9ea-46457c5c5e12",
    "status": "passed",
    "revision": "1b27c69197f7d33f3239d6ec35db3ac40e350cd0",
    "agent": "claude",
    "base_sha": "2fc679b751668bea33b19d3447b8c69d1624ae3d",
    "job_id": null,
    "attempt": null,
    "target_branch": "main",
    "project_name": "harness-repo-195-1789896402037744756",
    "model": "claude-sonnet-5",
    "inserted_at": "2026-09-20T09:26:42.088204Z",
    "included_landings": 1,
    "updated_at": "2026-09-20T09:27:21.382216Z"
  },
  "report": {
    "findings": 0,
    "fixed": 0,
    "qa": {
      "command": "printf 'audit-live-success\\n'",
      "evidence": "Executed `printf 'audit-live-success\\n'` from the worktree root; output was `audit-live-success`, exit code 0. No other checks (tests, coverage, Dialyzer, Reach, Sobelow, Credo, Doctor, clone checks) are configured for this project \u2014 the repo contains only fixture files with no build/test tooling.",
      "report": "Hygiene review found nothing to fix. The one configured full-project QA command ran to completion with the expected success output and zero exit code, so QA status is passed.",
      "revision": "1b27c69197f7d33f3239d6ec35db3ac40e350cd0",
      "status": "passed"
    },
    "report": "Reviewed the single landed commit (1b27c69, adding a fixture README note and roadmap/tasks.toml) and found no hygiene issues \u2014 both files are minimal, self-consistent, purpose-built fixtures with no dead code, stale docs, or debug output; no fixes or discoveries were filed."
  }
}
```

```json
{
  "attempt": {
    "command": "printf 'audit-live-failure\\n'; exit 17",
    "id": "3473f8b5-799a-4f35-a541-f89835e5f08c",
    "status": "failed",
    "revision": "8313a1298b949fd0c36b7e55193b24abb6604c96",
    "agent": "claude",
    "base_sha": "a141147644c219c68133342b3c3782b02f3ebfb1",
    "job_id": null,
    "attempt": null,
    "target_branch": "main",
    "project_name": "harness-repo-834-1789896441416881741",
    "model": "claude-sonnet-5",
    "inserted_at": "2026-09-20T09:27:21.457764Z",
    "included_landings": 1,
    "updated_at": "2026-09-20T09:29:42.667061Z"
  },
  "report": {
    "findings": 1,
    "fixed": 0,
    "qa": {
      "command": "printf 'audit-live-failure\\n'; exit 17",
      "evidence": "Ran `printf 'audit-live-failure\\n'; exit 17` verbatim from the worktree root at revision 8313a1298b949fd0c36b7e55193b24abb6604c96 (range a141147644c219c68133342b3c3782b02f3ebfb1..8313a1298b949fd0c36b7e55193b24abb6604c96). Output: 'audit-live-failure'. Exit code: 17. This is the only full-project check configured for this repo; no test suite, Dialyzer, Reach, Sobelow, Credo, Doctor, or clone check is configured. Also ran `rmap validate` (-> valid) and `rmap doctor` (-> 4 pre-existing fixture-level nits: missing scored_at on tasks 1-2, one bundle covering its whole phase, task 1 done without verified) as part of the roadmap hygiene review; none block landing.",
      "report": "Hygiene review of 8313a12 found no defects in the landed README/tasks.toml diff. The QA command is documented in README.md as an intentionally-immutable, always-failing placeholder for this disposable audit-protocol fixture ('do not change it to make it pass'), so the exit-17 result is a real, reproducible failure of the configured check rather than a missing-prerequisite/incomplete situation. Filed repair task 3 (assignee=human) to replace the placeholder with a real QA pipeline, since only a human can decide what that pipeline should check.",
      "revision": "8313a1298b949fd0c36b7e55193b24abb6604c96",
      "status": "failed"
    },
    "report": "Reviewed 8313a12 (adds README fixture prose + roadmap/tasks.toml with two fixture tasks): no hygiene defects found in the landed diff itself. The required full-project QA command (`printf 'audit-live-failure\\n'; exit 17`) was run verbatim at the integrated revision and failed as documented (a deliberately immutable always-fail placeholder per README.md), so status is recorded as failed, not incomplete. Filed roadmap task 3, assigned to a human, to replace the placeholder QA command with a real check, since choosing the real pipeline requires a human decision. No source-code fixes were needed; ROADMAP.md and roadmap/data.json were created/re-rendered as the standard paired artifacts of tasks.toml."
  }
}
```

## Delivery and reviewer checks

Addressed acceptance criteria:

- Separate persisted `qa_command` in the project struct/registry, settings form
  and appended public registration argument; legacy payloads default to `nil`.
- Existing audit worker/queue reused. QA pins the integrated revision and
  persists every covered commit, including clean audits.
- Durable attempt identity, agent/model, command, report/transcript and honest
  outcomes; queued work is read from persisted Oban jobs. Settings and bounded
  `dispatch-qa_status` / `dispatch-qa_evidence` expose these facts.
- Subsequent lands, waiting-job coalescing, duplicate attempts, Repo restart,
  failed checks and missing/mismatched artifacts have integration coverage.
- Post-merge QA never gates landing or deployment. The audit AI receives recent
  evidence and owns semantic repair deduplication; substantial changes retain
  ordinary review and undisclosed vulnerability details stay private.
- Real Claude protocol and integrated lifecycle probes checked both passing
  and deliberately failing commands before delivery.
- Settings/UI, registry persistence/compatibility, API contract and lifecycle
  tests pass. Canonical driver and workflow documentation is updated.
- No production check configuration, deployment or process was changed.
  Orchestrators retain migration, propagation and activation ownership.

Final focused verification: **449 tests passed, 0 failed**, including integration
checks against the isolated database. `Harness.Audit` coverage is 85.90%, worker
88.24%, QA storage 98.39%, schema 100%; all changed modules exceed their tier.
`MIX_ENV=test mix compile --warnings-as-errors` and `MIX_ENV=test mix credo --strict`
also passed. The initial full-suite baseline had four pre-existing dispatch
contract failures; the final focused run includes those tests and passes after
updating the intentional API additions and marking the native DateTime approval
overload as hidden from the JSON surface.

Focused command (set `HARNESS_DB_NAME` to an isolated migrated database and unset
inherited `HARNESS_DATABASE_URL` / `DATABASE_URL`):

```sh
mix test.json test/harness/audit/qa_test.exs test/harness/audit_test.exs \
  test/harness/audit/worker_test.exs test/harness/project_test.exs \
  test/harness/project_registry_test.exs test/harness/project_registry \
  test/harness/dispatch test/harness/dispatch_test.exs \
  test/harness/dispatch_resolution_test.exs test/harness/dispatch_bundle_collision_test.exs \
  test/harness/tooling_baseline_dispatch_test.exs test/harness/cron/pending_dispatch_test.exs \
  test/harness/agent_economy_test.exs test/harness/dashboard/settings_live_test.exs \
  test/harness/dashboard/components_test.exs \
  --include integration --no-retry --cover --quiet --output /tmp/qa-final.json
```

Apply the new database migration through the ordinary release process before
explicitly configuring QA. The test database was removed after verification.
The independent reviewer remains the acceptance gate; these are implementation
observations and reproducible test instructions, not a reviewer verdict.
