#!/usr/bin/env bash
# sync-harness-skills.sh — propagate harness's two canonical skill sources to every consumer.
#
# Harness owns two docs that the general marketplace sync
# (claude-marketplace/scripts/sync-skills-from-includes.sh) DELIBERATELY EXCLUDES —
# see that repo's scripts/skill-include-map.sh: "harness plugin's skills
# (harness-driver, harness-workflow) are NOT mapped here — they self-sync from their
# own canonical sources." THIS script is that self-sync. Run it after editing either
# canonical source below; otherwise the installed include and the marketplace skills
# silently drift from the source of truth.
#
# Canonical sources (here, in the harness repo — edit ONLY these):
#   priv/includes/harness-workflow.md   portfolio implement→review→land contract (plain include, no frontmatter)
#   skills/harness-driver/SKILL.md       AI-orchestrator driver surface (a full SKILL.md, with frontmatter)
#
# Destinations (never hand-edit — overwritten by this script):
#   ~/.claude/includes/harness-workflow.md                  (cp — same effect as `mix harness.install_includes`)
#   $MKT/plugins/harness/skills/harness-workflow/SKILL.md   (body synced; dest frontmatter preserved)
#   $MKT/plugins/harness/skills/harness-driver/SKILL.md     (body synced; dest frontmatter preserved)
#
# $MKT is $CLAUDE_MARKETPLACE_DIR when set, else the first candidate code root that
# holds a claude-marketplace checkout carrying plugins/harness. An explicitly-set
# CLAUDE_MARKETPLACE_DIR that does not resolve is a HARD ERROR: the operator named a
# destination and the script must not silently sync two of three legs. Only the
# unconfigured case skips (e.g. a fresh public clone without the private marketplace
# checkout), and it names every path it searched. The ~/.claude/includes leg always runs.
#
# Usage:
#   scripts/sync-harness-skills.sh            # propagate
#   scripts/sync-harness-skills.sh --dry-run  # show what would change, write nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Resolve the marketplace checkout. A candidate counts only if it carries the harness
# plugin — a name match alone would happily target the managed plugin cache clone,
# whose commits are discarded on the next /plugin reload.
MKT_CANDIDATES=(
  "$HOME/_DATA/code/claude-marketplace"
  "$HOME/code/claude-marketplace"
  "$(dirname "$REPO_ROOT")/claude-marketplace"
  "$(dirname "$(dirname "$REPO_ROOT")")/code/claude-marketplace"
)
MKT=""
MKT_EXPLICIT=false
if [[ -n "${CLAUDE_MARKETPLACE_DIR:-}" ]]; then
  MKT_EXPLICIT=true
  MKT="$CLAUDE_MARKETPLACE_DIR"
else
  for c in "${MKT_CANDIDATES[@]}"; do
    if [[ -d "$c/plugins/harness" ]]; then MKT="$c"; break; fi
  done
fi
INCLUDES_DIR="$HOME/.claude/includes"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

synced=0
skipped=0
errors=0

tildify() { printf '%s' "${1/#$HOME/\~}"; }

# write_if_changed <dest> <new_content>
write_if_changed() {
  local dest="$1" new="$2"
  if [[ -f "$dest" && "$(cat "$dest")" == "$new" ]]; then
    echo "OK:   $(tildify "$dest") (already in sync)"
    skipped=$((skipped + 1))
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo "WOULD SYNC: $(tildify "$dest")"
    synced=$((synced + 1))
    return
  fi
  printf '%s\n' "$new" >"$dest"
  echo "SYNCED: $(tildify "$dest")"
  synced=$((synced + 1))
}

# sync_skill_body <src_file> <dest_skill> <strip_src_frontmatter:true|false> <src_label>
# Preserves the DEST skill's frontmatter (so the marketplace `when-to-use` line and
# any plugin-specific keys survive) and replaces the body with the source content.
sync_skill_body() {
  local src="$1" dst="$2" strip="$3" label="$4"
  if [[ ! -f "$dst" ]]; then
    echo "SKIP: $(tildify "$dst") (dest skill not found)"
    skipped=$((skipped + 1))
    return
  fi

  # Frontmatter = everything up to and including the 2nd `---` line of the DEST.
  local frontmatter
  frontmatter="$(awk '/^---$/{c++; print; if(c==2) exit; next} {print}' "$dst")"
  if ! printf '%s' "$frontmatter" | head -1 | grep -q '^---$'; then
    echo "ERROR: $(tildify "$dst") (no valid frontmatter)"
    errors=$((errors + 1))
    return
  fi

  local body
  if [[ "$strip" == true ]]; then
    # Body = everything AFTER the source's own 2nd `---`, leading blank lines trimmed.
    body="$(awk '/^---$/{c++; if(c==2){f=1; next}} f' "$src" | awk 'NF{p=1} p')"
  else
    body="$(cat "$src")"
  fi

  write_if_changed "$dst" "${frontmatter}

<!-- Auto-synced from harness repo ${label} by scripts/sync-harness-skills.sh — do not edit here -->

${body}"
}

WF_SRC="$REPO_ROOT/priv/includes/harness-workflow.md"
DRIVER_SRC="$REPO_ROOT/skills/harness-driver/SKILL.md"

# Leg 1: workflow include -> ~/.claude/includes (equivalent to `mix harness.install_includes`).
mkdir -p "$INCLUDES_DIR"
write_if_changed "$INCLUDES_DIR/harness-workflow.md" "$(cat "$WF_SRC")"

# Legs 2 & 3: marketplace skills (skipped gracefully when the marketplace isn't checked out).
if [[ "$MKT_EXPLICIT" == true && ! -d "$MKT/plugins/harness" ]]; then
  echo "ERROR: CLAUDE_MARKETPLACE_DIR is set to '$MKT' but that is not a marketplace checkout" >&2
  echo "       (expected $MKT/plugins/harness). Refusing to sync only the includes leg." >&2
  exit 1
fi

if [[ -n "$MKT" && -d "$MKT/plugins/harness" ]]; then
  sync_skill_body "$WF_SRC" \
    "$MKT/plugins/harness/skills/harness-workflow/SKILL.md" false \
    "priv/includes/harness-workflow.md"
  sync_skill_body "$DRIVER_SRC" \
    "$MKT/plugins/harness/skills/harness-driver/SKILL.md" true \
    "skills/harness-driver/SKILL.md"
else
  echo "SKIP marketplace legs: no claude-marketplace checkout found. Searched:"
  for c in "${MKT_CANDIDATES[@]}"; do echo "         $c"; done
  echo "       Set CLAUDE_MARKETPLACE_DIR to sync them (an unresolvable value is an error, not a skip)."
fi

echo ""
echo "--- Summary --- synced=$synced skipped=$skipped errors=$errors"
[[ "$DRY_RUN" == true ]] && echo "(dry run — no files modified)"
[[ "$errors" -eq 0 ]]
