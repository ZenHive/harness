# Live agent pipeline smoke test

`test/harness/live_agent_e2e_test.exs` exercises the seam that the scripted
`pipeline_e2e_test.exs` cannot prove: authenticated implementer and reviewer CLIs,
with explicit model pins, through dispatch, review, landing and roadmap writeback.
It uses the same captured Oban insertion seam as the deterministic test, then
executes the real run and landing workers. It does not require PostgreSQL.

Install both CLIs and authenticate with subscription credentials:

```sh
npm install -g @openai/codex @anthropic-ai/claude-code
codex login
claude auth login
```

Git, GNU `timeout` (coreutils), and `rmap` must be on PATH. Install `rmap` with
`cargo install --path .` from its source checkout.

Choose an explicit supported Claude pin from the maintained catalog in
`Harness.ModelAvailability`; Codex pins are resolved against `codex debug models`
at execution. A successful live invocation is the provider-support check.

```sh
export HARNESS_LIVE_REVIEWER_MODEL=claude-sonnet-5
mix test.json test/harness/live_agent_e2e_test.exs --include live_agent --no-retry
```

| Variable | Default |
| --- | --- |
| `HARNESS_LIVE_IMPLEMENTER` | `codex` |
| `HARNESS_LIVE_IMPLEMENTER_MODEL` | `gpt-6-astra` for Codex; required for Claude |
| `HARNESS_LIVE_REVIEWER` | `claude` |
| `HARNESS_LIVE_REVIEWER_MODEL` | Required |

The smoke test supports Codex and Claude in either role and checks that their
adapter-declared model families are disjoint. It scrubs API-key environment
variables from agent invocations to use the authenticated subscription sessions.
Missing CLIs, authentication or model pins fail with setup instructions. The selected
pair is enabled in a private in-memory settings scope, leaving operator settings
untouched. `--no-retry` prevents the JSON runner from spending capacity on an
automatic retry of a failed live test.

Both `:integration` and `:live_agent` tags exclude it from routine tests and
`mix precommit` (`--exclude integration --exclude live_agent`). `--include live_agent`
opts in this smoke test only — other live-CLI tests stay behind `:integration`.
Each agent has a logged 240-second total timeout; the entire run also has a
240-second lifetime deadline. ExUnit bounds setup, dispatch and landing together
at 330 seconds. Cancellation terminates the run's agent processes before fixture
cleanup. The test uses only its own temporary repositories, worktrees and local
bare origin; it starts no server and enqueues no real audit agent.

Approval must leave `landed_sha` unset and the task in progress. Only after the
real lander pushes does the test accept success: the approved commit is reachable
from origin/main, the run's landing SHA matches `shipped_in`, and the completed
roadmap names the implementer, reviewer and harness run verification reference.
