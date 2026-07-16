#!/usr/bin/env bash
# launchd wrapper: append one log per run and notify only on partial failure/error.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${ZHANLU_SYNC_SCRIPT:-${SCRIPT_DIR}/../sync-zhanlu-gitlab-to-github.sh}"
VOLUME_ROOT="${ZHANLU_SYNC_VOLUME_ROOT:-/Volumes/Files}"
EXTERNAL_LOG_DIR="${ZHANLU_SYNC_EXTERNAL_LOG_DIR:-${VOLUME_ROOT}/.zhanlu-git-sync/logs}"
USER_HOME="${HOME:-}"
if [[ -z "$USER_HOME" ]]; then
	USER_HOME="$(cd ~ && pwd)"
	export HOME="$USER_HOME"
fi
DEFAULT_LOG_DIR="${ZHANLU_SYNC_DEFAULT_LOG_DIR:-${USER_HOME}/Library/Logs/ZhanluGitSync/runs}"
LOG_DIR=""

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export GIT_TERMINAL_PROMPT=0

notify_failure() {
	local message="$1"
	if [[ "${ZHANLU_SYNC_DISABLE_NOTIFICATIONS:-0}" == "1" ]]; then
		return 0
	fi
	/usr/bin/osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
	display notification (item 1 of argv) with title "Zhanlu Git 同步异常"
end run
APPLESCRIPT
}

can_use_log_dir() {
	local candidate="$1"
	local probe=""
	if ! mkdir -p "$candidate" 2>/dev/null; then
		return 1
	fi
	if ! probe="$(mktemp "${candidate}/.write-test.XXXXXX" 2>/dev/null)"; then
		return 1
	fi
	rm -f "$probe"
	return 0
}

is_mounted_volume() {
	if [[ "${ZHANLU_SYNC_SKIP_MOUNT_CHECK:-0}" == "1" ]]; then
		return 0
	fi
	mount | grep -F " on ${VOLUME_ROOT} (" >/dev/null 2>&1
}

if [[ ! -x "$SYNC_SCRIPT" ]]; then
	notify_failure "同步脚本不存在或不可执行。"
	echo "Sync script is unavailable: ${SYNC_SCRIPT}" >&2
	exit 2
fi

if [[ -n "${ZHANLU_SYNC_LOG_DIR:-}" ]]; then
	if can_use_log_dir "$ZHANLU_SYNC_LOG_DIR"; then
		LOG_DIR="$ZHANLU_SYNC_LOG_DIR"
	fi
elif [[ -d "$VOLUME_ROOT" ]] && is_mounted_volume && can_use_log_dir "$EXTERNAL_LOG_DIR"; then
	LOG_DIR="$EXTERNAL_LOG_DIR"
elif can_use_log_dir "$DEFAULT_LOG_DIR"; then
	LOG_DIR="$DEFAULT_LOG_DIR"
fi

if [[ -z "$LOG_DIR" ]]; then
	notify_failure "无法创建同步日志目录。"
	echo "Unable to create a writable synchronization log directory" >&2
	exit 2
fi

find "$LOG_DIR" -type f -name 'run-*.log' -mtime +30 -delete 2>/dev/null || true

timestamp="$(date '+%Y%m%d-%H%M%S')"
log_file="${LOG_DIR}/run-${timestamp}.log"
status=0

if ! {
	echo "==== $(date '+%Y-%m-%d %H:%M:%S %z') start ===="
	"$SYNC_SCRIPT" "$@" || status=$?
	echo "==== $(date '+%Y-%m-%d %H:%M:%S %z') end (exit ${status}) ===="
} >>"$log_file" 2>&1; then
	notify_failure "无法写入同步日志，定时同步未执行。"
	echo "Unable to write synchronization log: ${log_file}" >&2
	exit 2
fi

if [[ "$status" -ne 0 ]]; then
	notify_failure "同步退出码 ${status}，详情见 ${log_file}"
fi

exit "$status"
