#!/usr/bin/env bash
# Write repo-root .env before get_zhanlu.sh.
# CI: set a single GitHub Actions secret ZHANLU_ROOT_DOTENV to the full .env file contents.
# Local (optional): export ZHANLU_ROOT_DOTENV="$(cat .env)" or set individual vars below.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${_SCRIPT_DIR}"

if [[ -n "${ZHANLU_ROOT_DOTENV:-}" ]]; then
  printf '%s\n' "${ZHANLU_ROOT_DOTENV}" > .env
  echo "write_zhanlu_root_env: wrote .env from ZHANLU_ROOT_DOTENV"
  exit 0
fi

have_any=false
{
  [[ -n "${POSTHOG_API_KEY:-}" ]] && { printf 'POSTHOG_API_KEY=%s\n' "${POSTHOG_API_KEY}"; have_any=true; }
  [[ -n "${MARKETPLACE_AUTH_TOKEN:-}" ]] && { printf 'MARKETPLACE_AUTH_TOKEN=%s\n' "${MARKETPLACE_AUTH_TOKEN}"; have_any=true; }
  [[ -n "${ZHANLU_TOKEN_DECRYPT_KEY:-}" ]] && { printf 'ZHANLU_TOKEN_DECRYPT_KEY=%s\n' "${ZHANLU_TOKEN_DECRYPT_KEY}"; have_any=true; }
  [[ -n "${ZHANLU_API_URL:-}" ]] && { printf 'ZHANLU_API_URL=%s\n' "${ZHANLU_API_URL}"; have_any=true; }
  [[ -n "${CLERK_BASE_URL:-}" ]] && { printf 'CLERK_BASE_URL=%s\n' "${CLERK_BASE_URL}"; have_any=true; }
} > .env

if [[ "${have_any}" == true ]]; then
  echo "write_zhanlu_root_env: wrote .env from individual environment variables"
else
  rm -f .env
  echo "write_zhanlu_root_env: no ZHANLU_ROOT_DOTENV or partial keys set; skipped (no .env written)"
fi
