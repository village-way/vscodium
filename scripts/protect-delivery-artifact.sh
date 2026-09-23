#!/usr/bin/env bash
# zhanlu_change - new file
# Encrypt complete delivery assets for workflow-only validation without changing their contents.

set -euo pipefail
set +x
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -f delivery-assets.tar.enc
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
[[ -d assets ]] && [[ -n "$(find assets -type f -print -quit)" ]]
tar -cf "$archive" -C assets .
node "$SCRIPT_DIR/source-artifact.mjs" encrypt "$archive" delivery-assets.tar.enc
