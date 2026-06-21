#!/usr/bin/env bash
#
# agent-attribution-scrub.sh
#
# Strip or reject AI/model/private-identity authorship credits from commit
# messages and repository files. Enforces rules/attribution.md.
#
# This is the shared scrubber behind epic Decent-Tako/skills-and-governance#68
# (issue #70). A commit-msg hook (#71) calls `--check-message` to REJECT a
# disallowed trailer; `--fix-message` removes it in place; `--check-staged` and
# `--check-repo` audit file content.
#
# Deny patterns come from two sources:
#   1. rules/attribution-denylist.txt        — GENERIC AI/vendor/model credits,
#      committed. Anchored to trailer/credit syntax so ordinary prose mentioning
#      a model name is NOT flagged.
#   2. A runtime PRIVATE denylist, loaded IF PRESENT, NEVER committed (so the
#      scrubber cannot leak the private names it suppresses). All present sources
#      below are combined (patterns from each are applied). Locations:
#        a. rules/attribution-private-denylist.txt   (repo-local, gitignored)
#        b. $HOME/.config/agent-attribution/private-denylist.txt
#        c. $AGENT_ATTRIBUTION_PRIVATE_DENYLIST       (explicit path override)
#      Template: rules/attribution-private-denylist.txt.example
#
# Usage:
#   agent-attribution-scrub.sh --check-message <file|->
#   agent-attribution-scrub.sh --fix-message   <file>
#   agent-attribution-scrub.sh --check-staged
#   agent-attribution-scrub.sh --check-repo
#
# Exit codes:
#   0  clean (no disallowed attribution found) / fix applied
#   1  disallowed attribution found (check modes)
#   2  usage / environment error (bad args, missing file, no denylist)
#
# Portable to macOS bash 3.2 + BSD grep: no associative arrays; patterns are
# iterated via `grep -E -f`, never shell arrays; no GNU-only grep features.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GENERIC_DENYLIST="${AGENT_ATTRIBUTION_DENYLIST:-$REPO_ROOT/rules/attribution-denylist.txt}"

# Files excluded from --check-repo / --check-staged content scans: they legitimately
# contain attribution strings (the policy doc's anti-pattern examples, the denylist
# patterns themselves, and the deliberate test fixtures). Without this, the scanner
# would flag its own machinery. Paths are repo-root-relative, matched as ERE.
SELF_SCAN_EXCLUDE_RE='^(rules/attribution\.md|rules/attribution-denylist\.txt|rules/attribution-private-denylist\.txt(\.example)?|scripts/agent-attribution-scrub\.sh|hooks/INSTALL\.md|docs/agents/attribution-ci-rollout\.md|tests/test_agent_attribution_scrub\.py|tests/test_ci_attribution_check\.py)$'

usage() {
  sed -n '/^# Usage:/,/^# Portable/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;/^Portable/d'
}

die() { printf 'agent-attribution-scrub: %s\n' "$*" >&2; exit 2; }

# Echo the list of denylist files to use (generic + any present private ones).
# A missing private file is silently skipped; a missing generic file is fatal.
collect_denylists() {
  if [ ! -f "$GENERIC_DENYLIST" ]; then
    die "generic denylist not found: $GENERIC_DENYLIST"
  fi
  printf '%s\n' "$GENERIC_DENYLIST"

  local p
  for p in \
    "$REPO_ROOT/rules/attribution-private-denylist.txt" \
    "$HOME/.config/agent-attribution/private-denylist.txt" \
    "${AGENT_ATTRIBUTION_PRIVATE_DENYLIST:-}"; do
    if [ -n "$p" ] && [ -f "$p" ]; then
      printf '%s\n' "$p"
    fi
  done
}

# Build a single cleaned pattern file (comments + blank lines stripped) into the
# global PATTERN_FILE. grep -f treats EVERY line of a pattern file as a regex,
# including `#` comments and blank lines — and a blank line matches everything —
# so the raw denylists must never be handed to grep directly. The caller is
# responsible for `rm -f "$PATTERN_FILE"` when done (or rely on its mktemp slot).
PATTERN_FILE=""
build_pattern_file() {
  PATTERN_FILE="$(mktemp "${TMPDIR:-/tmp}/attr-scrub-pat.XXXXXX")"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Drop blank lines and # comments; keep real patterns.
    grep -v -E '^[[:space:]]*(#|$)' "$f" >>"$PATTERN_FILE" || true
  done <<EOF
$(collect_denylists)
EOF
  if [ ! -s "$PATTERN_FILE" ]; then
    rm -f "$PATTERN_FILE"
    die "no usable deny patterns after stripping comments from denylist(s)"
  fi
}

# Remediation guidance printed to stderr on any hit.
print_remediation() {
  {
    echo ""
    echo "Remediation:"
    echo "  - Commit messages: remove the trailer/footer entirely (body is enough)."
    echo "    Fix in place with: $0 --fix-message <commit-msg-file>"
    echo "  - File content: delete the attribution credit, or attribute to Ben /"
    echo "    decent.tech per rules/attribution.md."
    echo "  - Policy: rules/attribution.md (private identities + AI trailers stripped"
    echo "    from client-touching surfaces)."
  } >&2
}

# --- mode: --check-message <file|-> ---------------------------------------
# Non-zero exit if the message text contains disallowed attribution.
check_message() {
  local src="${1:-}"
  [ -n "$src" ] || die "--check-message requires a file or '-'"
  local text
  if [ "$src" = "-" ]; then
    text="$(cat)"
  else
    [ -f "$src" ] || die "message file not found: $src"
    text="$(cat "$src")"
  fi

  build_pattern_file
  local hits
  # grep returns 1 on no-match; capture without tripping set -e.
  set +e
  hits="$(printf '%s\n' "$text" | grep -n -E -f "$PATTERN_FILE")"
  local rc=$?
  set -e
  rm -f "$PATTERN_FILE"

  if [ "$rc" -eq 0 ]; then
    echo "DISALLOWED attribution in commit message:" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    print_remediation
    return 1
  fi
  return 0
}

# --- mode: --fix-message <file> -------------------------------------------
# Remove disallowed attribution lines in place; leave body intact. Idempotent.
fix_message() {
  local file="${1:-}"
  [ -n "$file" ] || die "--fix-message requires a file"
  [ -f "$file" ] || die "message file not found: $file"

  build_pattern_file
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/attr-scrub.XXXXXX")"

  # grep -v of the deny patterns keeps every non-attribution line. -v exits 0 as
  # long as >=1 line survives; guard set -e and treat "all lines stripped" (rc 1)
  # as an empty result rather than a failure.
  set +e
  grep -v -E -f "$PATTERN_FILE" "$file" >"$tmp"
  local rc=$?
  set -e
  rm -f "$PATTERN_FILE"
  if [ "$rc" -gt 1 ]; then
    rm -f "$tmp"
    die "grep failed while filtering $file"
  fi

  # Collapse a trailing run of blank lines left where a trailer block was, then
  # ensure exactly one terminating newline.
  awk 'BEGIN{n=0} {lines[NR]=$0} END{
    last=NR
    while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--
    for(i=1;i<=last;i++) print lines[i]
  }' "$tmp" >"$tmp.2"

  mv "$tmp.2" "$file"
  rm -f "$tmp"
  return 0
}

# --- shared content scanner ------------------------------------------------
# Scan a newline-delimited list of repo-relative file paths (on stdin) for
# disallowed attribution, honouring SELF_SCAN_EXCLUDE_RE. Returns 1 on any hit.
scan_files() {
  build_pattern_file
  local found=1   # 1 == clean (mirrors grep: we flip at the end)
  local rel abs hits rc
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # Skip our own machinery + the policy doc.
    if printf '%s\n' "$rel" | grep -q -E "$SELF_SCAN_EXCLUDE_RE"; then
      continue
    fi
    abs="$REPO_ROOT/$rel"
    [ -f "$abs" ] || continue
    set +e
    # -I: treat binary files as non-matching so coincidental bytes in images,
    # compiled artifacts, etc. cannot produce false "Binary file matches" hits.
    hits="$(grep -I -n -E -f "$PATTERN_FILE" "$abs")"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      found=0
      echo "DISALLOWED attribution in $rel:" >&2
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
    fi
  done
  rm -f "$PATTERN_FILE"

  if [ "$found" -eq 0 ]; then
    print_remediation
    return 1
  fi
  return 0
}

# --- mode: --check-staged --------------------------------------------------
check_staged() {
  cd "$REPO_ROOT"
  git rev-parse --git-dir >/dev/null 2>&1 || die "--check-staged must run inside a git repo"
  # Added/copied/modified/renamed staged files (text content only).
  git diff --cached --name-only --diff-filter=ACMR | scan_files
}

# --- mode: --check-repo ----------------------------------------------------
check_repo() {
  cd "$REPO_ROOT"
  git rev-parse --git-dir >/dev/null 2>&1 || die "--check-repo must run inside a git repo"
  # All tracked files in the working tree (ignored/untracked excluded by design).
  git ls-files | scan_files
}

main() {
  local mode="${1:-}"
  case "$mode" in
    --check-message) shift; check_message "${1:-}" ;;
    --fix-message)   shift; fix_message "${1:-}" ;;
    --check-staged)  shift; check_staged ;;
    --check-repo)    shift; check_repo ;;
    -h|--help|help|"") usage; [ -n "$mode" ] && exit 0 || exit 2 ;;
    *) die "unknown mode: $mode (try --help)" ;;
  esac
}

main "$@"
