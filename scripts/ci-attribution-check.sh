#!/usr/bin/env bash
#
# ci-attribution-check.sh
#
# CI-side wrapper around agent-attribution-scrub.sh. Runs the shared scrubber in
# CHECK-ONLY mode over (a) every commit message in a PR range and (b) the file
# content of the tree, FAILING the job with precise remediation if any
# disallowed AI/model/private-identity attribution is present.
#
# This wrapper NEVER rewrites a commit object. It only reads commit messages
# (`git log --format=%B`) and tracked file content. Remote history is untouched;
# the remediation is performed by the human/agent locally (commit --amend /
# interactive rebase), not by CI.
#
# Issue: Decent-Tako/skills-and-governance#72 (CI + ruleset attribution
# enforcement), child of epic #68.
#
# Usage:
#   ci-attribution-check.sh <base-ref> <head-ref>
#
#   <base-ref>  merge-base side of the PR (e.g. origin/main or
#               github.event.pull_request.base.sha)
#   <head-ref>  PR tip (e.g. github.event.pull_request.head.sha or HEAD)
#
# Environment:
#   SCRUB            path to agent-attribution-scrub.sh
#                    (default: alongside this script in scripts/)
#   SKIP_REPO_SCAN   if set to "1", skip the file-content tree scan and check
#                    only commit messages. Use this in repos that have not yet
#                    been cleaned of PRE-EXISTING attribution in files, so the
#                    gate still blocks NEW leaks in commit messages without
#                    failing on unrelated legacy content. (See rollout doc.)
#
# Exit codes:
#   0  clean
#   1  disallowed attribution found (commit message and/or file content)
#   2  usage / environment error
#
# Portable to bash 3.2 + BSD/GNU grep (no associative arrays, no mapfile).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUB="${SCRUB:-$SCRIPT_DIR/agent-attribution-scrub.sh}"

die() { printf 'ci-attribution-check: %s\n' "$*" >&2; exit 2; }

[ $# -eq 2 ] || die "usage: ci-attribution-check.sh <base-ref> <head-ref>"
BASE_REF="$1"
HEAD_REF="$2"

[ -x "$SCRUB" ] || die "scrubber not found or not executable: $SCRUB"

# Single reusable scratch file for per-commit scrubber output; cleaned on exit.
tmp="$(mktemp "${TMPDIR:-/tmp}/attr-msg.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

fail=0

# ---------------------------------------------------------------------------
# (a) Commit messages across the PR range.
#
# We resolve the symmetric-difference base so a PR that lags main does not have
# main's commits re-scanned. Every commit is checked; we DO NOT stop at the
# first offender — "precise remediation" means naming every bad commit.
# ---------------------------------------------------------------------------
set +e
range_base="$(git merge-base "$BASE_REF" "$HEAD_REF" 2>&1)"
mb_rc=$?
set -e
if [ "$mb_rc" -ne 0 ]; then
  die "cannot compute merge-base of '$BASE_REF' and '$HEAD_REF' (shallow checkout? need fetch-depth: 0): ${range_base}"
fi

commits="$(git rev-list "$range_base..$HEAD_REF")"

if [ -z "$commits" ]; then
  echo "No commits in range $BASE_REF..$HEAD_REF — nothing to check for commit messages."
else
  echo "Checking commit messages in range ${range_base}..${HEAD_REF}"
  bad_commits=""
  # Iterate via heredoc-fed `read` (NOT `for sha in $commits`, which word-splits
  # on IFS, nor `… | while`, whose subshell would discard fail/bad_commits).
  while IFS= read -r sha || [ -n "$sha" ]; do
    [ -n "$sha" ] || continue
    # Feed the full commit message to the scrubber on stdin (check-only).
    if ! git log -1 --format=%B "$sha" | "$SCRUB" --check-message - >"$tmp" 2>&1; then
      short="$(git log -1 --format=%s "$sha")"
      echo ""
      echo "::error::Disallowed attribution in commit message of $sha"
      echo "  commit: $sha  ${short}"
      sed 's/^/  /' "$tmp"
      bad_commits="$bad_commits $sha"
      fail=1
    fi
  done <<EOF
$commits
EOF
  if [ -n "$bad_commits" ]; then
    echo ""
    echo "Offending commits:$bad_commits"
  else
    echo "  OK — no disallowed attribution in any commit message in range."
  fi
fi

# ---------------------------------------------------------------------------
# (b) File content of the tree (the scrubber scans REPO_ROOT = this checkout's
# tracked files). Skippable for repos not yet cleaned of legacy content.
# ---------------------------------------------------------------------------
if [ "${SKIP_REPO_SCAN:-0}" = "1" ]; then
  echo ""
  echo "SKIP_REPO_SCAN=1 — skipping file-content tree scan (commit messages only)."
else
  echo ""
  echo "Checking file content of the working tree (tracked files)..."
  # Capture the scrubber's combined output so we can both surface it and lift the
  # offending file names into per-file ::error:: annotations (the scrubber emits
  # "DISALLOWED attribution in <rel>:" headers on stderr).
  set +e
  "$SCRUB" --check-repo >"$tmp" 2>&1
  repo_rc=$?
  set -e
  cat "$tmp"
  if [ "$repo_rc" -ne 0 ]; then
    # One ::error:: per named file, mirroring the commit-message path's GHA
    # annotations; fall back to a generic line if no file header was parsed.
    named=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "::error file=$f::Disallowed attribution in tracked file: $f"
      named=1
    done <<EOF
$(sed -n 's/^DISALLOWED attribution in \(.*\):$/\1/p' "$tmp")
EOF
    [ "$named" -eq 1 ] || echo "::error::Disallowed attribution found in tracked file content (see above)."
    fail=1
  else
    echo "  OK — no disallowed attribution in tracked file content."
  fi
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

============================================================================
ATTRIBUTION CHECK FAILED — this PR carries disallowed AI / model / private-
identity attribution. CI is CHECK-ONLY and will not rewrite your commits.

Fix it locally, then force-push the branch:

  Commit MESSAGE trailers (e.g. "Co-Authored-By: <model>", "Generated with ..."):
    - Newest commit:   git commit --amend         (delete the trailer line)
    - Older commit(s): git rebase -i <base>        (reword each flagged commit)
      or use the scrubber's in-place fixer on a message file (run the vendored
      copy of agent-attribution-scrub.sh that ships alongside this script):
        agent-attribution-scrub.sh --fix-message <msg-file>

  FILE content:
    - Delete the attribution credit, or attribute to Ben / decent.tech
      per rules/attribution.md.

Policy: rules/attribution.md. This gate exists because commit messages are
immutable once merged — strip attribution on the way IN, not after.
============================================================================
EOF
  exit 1
fi

echo ""
echo "Attribution check passed."
exit 0
