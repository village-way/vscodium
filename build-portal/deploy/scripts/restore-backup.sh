#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then echo "usage: $0 <dump-file> <restore-database-url>" >&2; exit 2; fi
[[ -f "$1" ]] || { echo "dump file not found" >&2; exit 2; }
pg_restore --exit-on-error --clean --if-exists --no-owner --dbname "$2" "$1"
