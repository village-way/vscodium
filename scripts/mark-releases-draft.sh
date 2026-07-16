#!/usr/bin/env bash
# zhanlu_change - new file - mark published GitHub releases as draft
#
# Mark published releases as draft so only collaborators with write access can see them.
# Supports retries (network timeouts) and idempotent re-runs (already-draft is OK/skip).
#
# Usage:
#   ./scripts/mark-releases-draft.sh [--repo owner/name] [--limit N]
#   ./scripts/mark-releases-draft.sh --repo village-way/vscodium --apply
#   ./scripts/mark-releases-draft.sh --apply --retries 5 --retry-delay 10
#
# Default is dry-run (lists tags that would be changed). Pass --apply to edit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils.sh
. "${SCRIPT_DIR}/../utils.sh"

REPO="village-way/vscodium"
LIMIT=1000
APPLY=false
RETRIES=5
RETRY_DELAY=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:?--repo requires owner/name}"
      shift 2
      ;;
    --limit)
      LIMIT="${2:?--limit requires a number}"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --retries)
      RETRIES="${2:?--retries requires a number}"
      shift 2
      ;;
    --retry-delay)
      RETRY_DELAY="${2:?--retry-delay requires seconds}"
      shift 2
      ;;
    --help|-h)
      cat << EOF
Usage: ./scripts/mark-releases-draft.sh [options]

Options:
  --repo owner/name   Target repository (default: village-way/vscodium)
  --limit N           Max releases to list (default: 1000)
  --apply             Actually mark published releases as draft
  --retries N         Attempts per API call (default: 5)
  --retry-delay SEC   Base delay between retries; doubles each time (default: 5)
  --help              Show this help

Without --apply, only prints the tags that would be changed (dry-run).
Re-running --apply is safe: releases already in draft are skipped.
Requires gh CLI auth with contents:write on the target repository.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

# Run a command with retries. Returns 0 on success, 1 after exhausting retries.
# Stdout of the successful attempt is written to the path in $1; remaining args are the command.
retry_cmd_to() {
  local out_file="$1"
  shift
  local attempt=1
  local delay="${RETRY_DELAY}"
  local exit_code=0

  while (( attempt <= RETRIES )); do
    if "$@" >"${out_file}"; then
      return 0
    fi
    exit_code=$?
    : >"${out_file}"
    if (( attempt == RETRIES )); then
      break
    fi
    echo "  retry ${attempt}/${RETRIES} failed (exit ${exit_code}); sleeping ${delay}s..." >&2
    sleep "${delay}"
    delay=$(( delay * 2 ))
    if (( delay > 60 )); then
      delay=60
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# Run a command with retries; stdout goes to the caller (last successful attempt only via temp file).
retry_cmd() {
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  if retry_cmd_to "${tmp}" "$@"; then
    cat "${tmp}"
    return 0
  fi
  return 1
}

list_releases_json() {
  # gh release list --json requires a newer gh than 2.42; use REST for compatibility.
  # --paginate emits one JSON array per page; jq -s 'add' merges them.
  local raw
  if ! raw="$(retry_cmd gh api --paginate "repos/${REPO}/releases?per_page=100")"; then
    return 1
  fi
  echo "${raw}" | jq -s --argjson limit "${LIMIT}" \
    'add // [] | map({tagName: .tag_name, isDraft: .draft}) | .[:$limit]'
}

# Return 0 if tag is still a published (non-draft) release; 1 if draft/absent; 2 if lookup failed.
is_published_release() {
  local tag="$1"
  local json
  local state

  # Prefer direct view when the tag is still attached.
  if json="$(retry_cmd gh release view "${tag}" --repo "${REPO}" --json isDraft)"; then
    state="$(echo "${json}" | jq -r '.isDraft')"
    if [[ "${state}" == "true" ]]; then
      return 1
    fi
    if [[ "${state}" == "false" ]]; then
      return 0
    fi
  fi

  # Draft conversion may leave an untagged release; fall back to list membership.
  if ! json="$(list_releases_json)"; then
    return 2
  fi
  if echo "${json}" | jq -e --arg t "${tag}" '.[] | select(.tagName == $t and .isDraft == false)' >/dev/null; then
    return 0
  fi
  return 1
}

echo "Repository: ${REPO}"
echo "Limit: ${LIMIT}"
echo "Retries: ${RETRIES} (base delay ${RETRY_DELAY}s)"
if [[ "${APPLY}" == "true" ]]; then
  echo "Mode: APPLY (will mark published releases as draft)"
else
  echo "Mode: dry-run (pass --apply to make changes)"
fi
echo

RELEASES_JSON=""
if ! RELEASES_JSON="$(list_releases_json)"; then
  echo "Failed to list releases for ${REPO} after ${RETRIES} attempts." >&2
  exit 1
fi

PUBLISHED_TAGS="$(echo "${RELEASES_JSON}" | jq -r '.[] | select(.isDraft == false) | .tagName')"

if [[ -z "${PUBLISHED_TAGS}" ]]; then
  echo "No published (non-draft) releases found. Nothing to do."
  exit 0
fi

COUNT="$(echo "${PUBLISHED_TAGS}" | grep -c . || true)"
echo "Found ${COUNT} published release(s) to mark as draft:"
echo "${PUBLISHED_TAGS}" | while IFS= read -r TAG; do
  [[ -n "${TAG}" ]] || continue
  echo "  - ${TAG}"
done
echo

if [[ "${APPLY}" != "true" ]]; then
  echo "Dry-run complete. Re-run with --apply to mark these releases as draft."
  exit 0
fi

OK=0
SKIPPED=0
FAILED=0
FAILED_TAGS=()

while IFS= read -r TAG; do
  [[ -n "${TAG}" ]] || continue
  echo "Marking ${TAG} as draft..."

  status=0
  is_published_release "${TAG}" || status=$?
  if [[ "${status}" -eq 1 ]]; then
    echo "  SKIP (already draft or not published): ${TAG}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if [[ "${status}" -eq 2 ]]; then
    echo "  warn: could not verify current state; attempting edit..." >&2
  fi

  if retry_cmd gh release edit "${TAG}" --repo "${REPO}" --draft >/dev/null; then
    sync_release_download_ref "${REPO}" "${TAG}" "--draft" || echo "  warn: could not refresh download links in release notes for ${TAG}" >&2
    echo "  OK: ${TAG}"
    OK=$((OK + 1))
    continue
  fi

  # Idempotent recovery: client timeout may hide a server-side success
  # (including draft releases that become untagged-*).
  status=0
  is_published_release "${TAG}" || status=$?
  if [[ "${status}" -eq 1 ]]; then
    sync_release_download_ref "${REPO}" "${TAG}" "--draft" || echo "  warn: could not refresh download links in release notes for ${TAG}" >&2
    echo "  OK (verified not published after retry): ${TAG}"
    OK=$((OK + 1))
    continue
  fi

  echo "  FAILED: ${TAG}" >&2
  FAILED=$((FAILED + 1))
  FAILED_TAGS+=("${TAG}")
done <<< "${PUBLISHED_TAGS}"

echo
echo "Summary: ok=${OK} skipped=${SKIPPED} failed=${FAILED} total=${COUNT}"

if [[ "${FAILED}" -gt 0 ]]; then
  echo "Failed tags:" >&2
  for TAG in "${FAILED_TAGS[@]}"; do
    echo "  - ${TAG}" >&2
  done
  echo "Re-run the same command; already-draft releases will be skipped." >&2
  exit 1
fi

echo "Done."
