#!/usr/bin/env bash
# zhanlu_change - new file
# Scope ephemeral authentication to each Git invocation and reject credential URLs.

_BUILD_GIT_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-credential-env.sh"
validate_source_url() {
  if [[ ! "$1" =~ ^https?://[a-zA-Z0-9.-]+/[a-zA-Z0-9_./-]+$ ]]; then
    echo 'Error: repository URL must not contain credentials, query parameters or control characters' >&2
    return 1
  fi
}
secure_git() (
  set +x
  local helper
  printf -v helper '%q' "$_BUILD_GIT_HELPER"
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
  export GIT_TRACE=0 GIT_TRACE_CURL=0 GIT_CURL_VERBOSE=0 GIT_TRACE_PACKET=0
  export GIT_TRACE_SETUP=0 GIT_TRACE_PERFORMANCE=0 GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
  command git -c credential.helper= -c "credential.helper=!bash $helper" \
    -c http.extraHeader= -c http.followRedirects=false "$@"
)
