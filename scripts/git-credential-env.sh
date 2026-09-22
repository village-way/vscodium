#!/usr/bin/env bash
# zhanlu_change - new file
# Supply GitHub credentials only through Git's credential pipe; never persist them.

set +x
if [[ "${1:-}" != get ]]; then
  exit 0
fi
protocol='' host=''
while IFS='=' read -r key value; do
  case "$key" in
    protocol) protocol="$value" ;;
    host) host="$value" ;;
  esac
done
if [[ "$protocol" == https && "$host" == github.com && -n "${ZHANLU_GITHUB_TOKEN:-}" ]]; then
  printf 'username=x-access-token\npassword=%s\n' "$ZHANLU_GITHUB_TOKEN"
fi
