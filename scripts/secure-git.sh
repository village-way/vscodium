#!/usr/bin/env bash
# zhanlu_change - new file
# Scope ephemeral authentication to each Git invocation and reject credential URLs.

_BUILD_GIT_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-credential-env.sh"
validate_source_url() {
  if [[ "$1" == *[[:space:]]* || ! "$1" =~ ^https?://[a-zA-Z0-9.-]+/[a-zA-Z0-9_./-]+$ ]]; then
    echo 'Error: repository URL must not contain credentials, query parameters or control characters' >&2
    return 1
  fi
}
secure_git() (
  set +x
  local helper
  printf -v helper '%q' "$_BUILD_GIT_HELPER"
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
  # Git enables curl tracing whenever GIT_CURL_VERBOSE is set, even to 0, so clear these instead.
  unset GIT_TRACE GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE GIT_TRACE_PACKET GIT_TRACE_PACKFILE
  unset GIT_TRACE_SETUP GIT_TRACE_PERFORMANCE GIT_TRACE_REDACT GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
  command git -c credential.helper= -c "credential.helper=!bash $helper" \
    -c http.extraHeader= -c http.followRedirects=false "$@"
)
