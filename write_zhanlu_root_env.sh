#!/usr/bin/env bash
# Write zhanlu-code repo-root .env (this directory) before get_zhanlu.sh.
# prepare_zhanlu.sh copies it into vscode/extensions/zhanlu/.env for the builtin app bundle;
# it is not part of the VSIX (see packages/kilo-vscode/.vscodeignore in zhanlu-vs).
# CI: set GitHub Actions secret ZHANLU_ROOT_DOTENV to the full .env file contents.
# Local (optional): export ZHANLU_ROOT_DOTENV="$(cat .env)" or set individual vars below.
# zhanlu_change - document merge path for builtin .env

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${_SCRIPT_DIR}"

# zhanlu_change start - bundled plugins resolve secrets through ${ENV:...}, so a missing key
# silently ships a release where those MCP servers never register. Fail the release build instead.
ZHANLU_REQUIRED_ROOT_ENV_KEYS=(
  ZHANLU_CMDEVOPS_API_KEY
)

check_required_root_env_keys() {
  local missing=()
  local key

  for key in "${ZHANLU_REQUIRED_ROOT_ENV_KEYS[@]}"; do
    if [[ -f .env ]] && grep -Eq "^${key}=.+" .env; then
      continue
    fi
    missing+=("${key}")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "${VSCODE_QUALITY:-}" == "stable" && -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "write_zhanlu_root_env: error: .env is missing required key(s): ${missing[*]}" >&2
    echo "write_zhanlu_root_env: stable release builds require them; check the ZHANLU_ROOT_DOTENV secret" >&2
    return 1
  fi

  echo "write_zhanlu_root_env: warning: .env is missing key(s): ${missing[*]}" >&2
  echo "write_zhanlu_root_env: bundled plugin features depending on them will be unavailable" >&2
  return 0
}
# zhanlu_change end

if [[ -n "${ZHANLU_ROOT_DOTENV:-}" ]]; then
  printf '%s\n' "${ZHANLU_ROOT_DOTENV}" > .env
  echo "write_zhanlu_root_env: wrote .env from ZHANLU_ROOT_DOTENV"
  check_required_root_env_keys # zhanlu_change
  exit 0
fi

have_any=false
{
  [[ -n "${POSTHOG_API_KEY:-}" ]] && { printf 'POSTHOG_API_KEY=%s\n' "${POSTHOG_API_KEY}"; have_any=true; }
  [[ -n "${MARKETPLACE_AUTH_TOKEN:-}" ]] && { printf 'MARKETPLACE_AUTH_TOKEN=%s\n' "${MARKETPLACE_AUTH_TOKEN}"; have_any=true; }
  [[ -n "${ZHANLU_TOKEN_DECRYPT_KEY:-}" ]] && { printf 'ZHANLU_TOKEN_DECRYPT_KEY=%s\n' "${ZHANLU_TOKEN_DECRYPT_KEY}"; have_any=true; }
  # zhanlu_change - bundled lingji-alpha MCP servers resolve this through ${ENV:...}
  [[ -n "${ZHANLU_CMDEVOPS_API_KEY:-}" ]] && { printf 'ZHANLU_CMDEVOPS_API_KEY=%s\n' "${ZHANLU_CMDEVOPS_API_KEY}"; have_any=true; }
  [[ -n "${ZHANLU_API_URL:-}" ]] && { printf 'ZHANLU_API_URL=%s\n' "${ZHANLU_API_URL}"; have_any=true; }
  [[ -n "${CLERK_BASE_URL:-}" ]] && { printf 'CLERK_BASE_URL=%s\n' "${CLERK_BASE_URL}"; have_any=true; }
} > .env

if [[ "${have_any}" == true ]]; then
  echo "write_zhanlu_root_env: wrote .env from individual environment variables"
else
  rm -f .env
  echo "write_zhanlu_root_env: no ZHANLU_ROOT_DOTENV or partial keys set; skipped (no .env written)"
fi

check_required_root_env_keys # zhanlu_change
