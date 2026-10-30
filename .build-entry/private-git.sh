#!/usr/bin/env bash
# Run one private-repository operation with an isolated, repository-scoped SSH agent.
set +x
set -euo pipefail
for trace_name in ${!GIT_TRACE@} GIT_CURL_VERBOSE; do
  unset "$trace_name"
done

repository="${PRIVATE_SOURCE_REPOSITORY:-}"
if [[ ! "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo 'Invalid private source repository.' >&2
  exit 1
fi
if [[ -z "${PRIVATE_SOURCE_DEPLOY_KEY:-}" || $# -eq 0 ]]; then
  echo 'Private source deploy key and command are required.' >&2
  exit 1
fi

# A successful authenticated SSH probe plus an anonymous API 404 proves this
# repository exists without exposing it publicly. Any ambiguous response fails closed.
private_status="$(curl --silent --show-error --connect-timeout 15 --max-time 30 --output /dev/null --write-out '%{http_code}' \
  "https://api.github.com/repos/${repository}")"
if [[ "$private_status" != '404' ]]; then
  echo 'Private storage visibility could not be verified.' >&2
  exit 1
fi

transport_dir="$(mktemp -d)"
agent_started=false
ssh_agent=ssh-agent
ssh_add=ssh-add
ssh_binary=ssh
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Keep the agent and client in the same Git Bash/MSYS socket implementation.
    ssh_agent=/usr/bin/ssh-agent
    ssh_add=/usr/bin/ssh-add
    ssh_binary=/usr/bin/ssh
    ;;
esac
for transport_tool in "$ssh_agent" "$ssh_add" "$ssh_binary"; do
  if ! command -v "$transport_tool" >/dev/null; then
    echo 'Required private transport SSH tool is unavailable.' >&2
    exit 1
  fi
done
cleanup() {
  if [[ "$agent_started" == true ]]; then
    "$ssh_agent" -k >/dev/null 2>&1 || true
  fi
  rm -rf "$transport_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# GitHub's published Ed25519 host key, also used by ssh.github.com on port443:
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
printf '%s\n' '[ssh.github.com]:443 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$transport_dir/known_hosts"
unset SSH_AUTH_SOCK SSH_AGENT_PID
agent_environment="$("$ssh_agent" -s)"
eval "$agent_environment" >/dev/null
unset agent_environment
agent_started=true
if ! printf '%s\n' "$PRIVATE_SOURCE_DEPLOY_KEY" | "$ssh_add" - >/dev/null 2>&1; then
  echo 'Could not load the scoped private source deploy key.' >&2
  exit 1
fi
unset PRIVATE_SOURCE_DEPLOY_KEY
printf -v quoted_hosts '%q' "$transport_dir/known_hosts"
export GIT_SSH_COMMAND="\"${ssh_binary}\" -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 -o ServerAliveInterval=20 -o ServerAliveCountMax=2 -o UserKnownHostsFile=${quoted_hosts} -p 443"
# Git for Windows cannot reliably infer the variant from an MSYS command path.
export GIT_SSH_VARIANT=ssh
export GIT_TERMINAL_PROMPT=0

# Rewrite only this exact repository, within this process; never persist credentials/config.
config_index="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${config_index}=url.ssh://git@ssh.github.com:443/${repository}.git.insteadOf"
export "GIT_CONFIG_VALUE_${config_index}=https://github.com/${repository}.git"
export GIT_CONFIG_COUNT="$((config_index + 1))"
git ls-remote "https://github.com/${repository}.git" >/dev/null
export PRIVATE_SOURCE_TRANSPORT_VERIFIED="$repository"
"$@"
