#!/usr/bin/env bash
# Focused generator contract tests; every mutation is inside an isolated export.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts" "$tmp/repo/priv/includes" "$tmp/empty-home"
cp "$root/CLAUDE.md" "$root/AGENTS.md" "$tmp/repo/"
cp "$root/scripts/sync-agents-md.sh" "$tmp/repo/scripts/"
cp -R "$root/priv/agents" "$tmp/repo/priv/"
cp "$root/priv/includes/harness-workflow.md" "$tmp/repo/priv/includes/"
cd "$tmp/repo"

render() { env HOME="$tmp/empty-home" bash scripts/sync-agents-md.sh "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  local message="$1"
  shift
  if render "$@" >"$tmp/output" 2>&1; then
    fail "expected failure: $message"
  fi
  grep -F -- "$message" "$tmp/output" >/dev/null || fail "missing diagnostic: $message"
}

# Delivered inputs suffice with no developer installation or git metadata.
render --check
render
cmp AGENTS.md "$root/AGENTS.md"
cp AGENTS.md "$tmp/expected"
render
cmp AGENTS.md "$tmp/expected"
render --check

# Compare the unmodified upstream algorithm using exactly the same snapshots.
mkdir -p "$tmp/upstream-home/.claude/includes"
cp priv/agents/includes/*.md "$tmp/upstream-home/.claude/includes/"
cp priv/includes/harness-workflow.md "$tmp/upstream-home/.claude/includes/"
env HOME="$tmp/upstream-home" bash "$root/test/fixtures/agents/upstream-sync-agents-md.sh"
cmp AGENTS.md "$tmp/expected"

printf '\nmanual drift\n' >> AGENTS.md
cp AGENTS.md "$tmp/drift"
expect_failure 'STALE:' --check
cmp AGENTS.md "$tmp/drift"
render
rm AGENTS.md
expect_failure 'is missing' --check
render

# Recursive imports preserve upstream whitespace and catch transitive drift.
printf '\n@~/.claude/includes/nested.md\n' >> priv/agents/includes/critical-rules.md
printf 'nested source without terminal newline' > priv/agents/includes/nested.md
render
cp AGENTS.md "$tmp/nested"
cp priv/agents/includes/*.md "$tmp/upstream-home/.claude/includes/"
env HOME="$tmp/upstream-home" bash "$root/test/fixtures/agents/upstream-sync-agents-md.sh"
cmp AGENTS.md "$tmp/nested"
printf '\nchanged\n' >> priv/agents/includes/nested.md
expect_failure 'STALE:' --check
render
cp AGENTS.md "$tmp/before-error"
rm priv/agents/includes/nested.md
# Even an available HOME copy must not mask a missing vendored source.
mkdir -p "$tmp/empty-home/.claude/includes"
cp "$tmp/upstream-home/.claude/includes/nested.md" "$tmp/empty-home/.claude/includes/"
expect_failure 'cannot read @-import: ~/.claude/includes/nested.md'
cmp AGENTS.md "$tmp/before-error"
expect_failure 'cannot read @-import: ~/.claude/includes/nested.md' --check

printf '@~/.claude/includes/nested.md\n' > priv/agents/includes/nested.md
expect_failure '@-import depth exceeded 5'
cmp AGENTS.md "$tmp/before-error"
printf '@~/unvendored.md\n' > priv/agents/includes/nested.md
expect_failure 'unsupported home @-import: ~/unvendored.md'
cmp AGENTS.md "$tmp/before-error"

cp "$root/priv/agents/includes/critical-rules.md" priv/agents/includes/critical-rules.md
rm priv/includes/harness-workflow.md
expect_failure 'cannot read @-import: ~/.claude/includes/harness-workflow.md'
cmp AGENTS.md "$tmp/before-error"
echo 'PASS: portable rendering, upstream parity, idempotence, drift, missing imports, depth and HOME isolation'
