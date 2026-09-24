#!/usr/bin/env bash
# zhanlu_change - new file
# Prepare an extracted source tree for local patching and restore runtime configuration
# from the current job's secret material without putting it in the intermediate archive.

set -euo pipefail
set +x

SOURCE_ROOT="${1:-vscode}"
# A fresh repository prevents git apply/config from discovering the outer build checkout.
# It has no commits, remotes or credentials and is never re-uploaded.
git -C "${SOURCE_ROOT}" init -q

for resource_root in \
  "${SOURCE_ROOT}/zhanlu-agent/packages/agent-core" \
  "${SOURCE_ROOT}/.build/zhanlu-agent-resources"; do
  if [[ -f "${resource_root}/agent-resources-manifest.json" ]]; then
    if [[ -f .env ]]; then
      (umask 077; cp .env "${resource_root}/.env")
    fi
  fi
done
