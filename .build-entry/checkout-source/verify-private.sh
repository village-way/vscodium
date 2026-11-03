#!/usr/bin/env bash
# Verify source visibility with the scoped credential without printing response bodies or tokens.

set -euo pipefail
[[ "${SELECTED_REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
[[ -n "${VISIBILITY_TOKEN:-}" ]]
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
status="$(curl --silent --show-error --max-time 30 --output "$response" --write-out '%{http_code}' \
  --header "Authorization: Bearer $VISIBILITY_TOKEN" "https://api.github.com/repos/$SELECTED_REPOSITORY")"
if [[ "$status" == 200 ]]; then
  python3 - "$response" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    if json.load(source).get("private") is not True:
        raise SystemExit("Public source repositories are not allowed")
PY
elif [[ "$status" == 404 && "${HAS_DEPLOY_KEY:-false}" == true ]]; then
  # A repository-scoped SSH key cannot query the REST API. The workflow token
  # must see no public repository, and the subsequent authenticated checkout must succeed.
  exit 0
else
  echo "Private source visibility could not be verified (HTTP $status)" >&2
  exit 1
fi
