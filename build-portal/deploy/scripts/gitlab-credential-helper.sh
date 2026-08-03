#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "get" || -z "${GITLAB_TOKEN:-}" ]]; then exit 1; fi
printf 'username=oauth2\npassword=%s\n' "${GITLAB_TOKEN}"
