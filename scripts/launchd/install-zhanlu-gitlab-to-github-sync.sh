#!/usr/bin/env bash
# Install, inspect, or uninstall the per-user LaunchAgent and its runtime copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${ZHANLU_SYNC_RUNTIME_DIR:-${HOME}/Library/Application Support/ZhanluGitSync}"
RUNTIME_LAUNCHD_DIR="${RUNTIME_DIR}/launchd"
AGENT_DIR="${HOME}/Library/LaunchAgents"
AGENT_PATH="${AGENT_DIR}/com.zhanlu.sync-origin-upstream.plist"
LAUNCHD_LOG_DIR="${HOME}/Library/Logs/ZhanluGitSync"
EXTERNAL_CACHE_ROOT="${ZHANLU_SYNC_EXTERNAL_CACHE_ROOT:-/Volumes/Files/.zhanlu-git-sync/cache}"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.zhanlu.sync-origin-upstream.plist"
RUNNER_PATH="${RUNTIME_LAUNCHD_DIR}/run-zhanlu-gitlab-to-github-sync.sh"
LABEL="com.zhanlu.sync-origin-upstream"
DOMAIN="gui/$(id -u)"
ACTION="${1:-install}"
TEMP_PLIST=""

usage() {
	cat <<'EOF'
Usage: install-zhanlu-gitlab-to-github-sync.sh [install|uninstall|status]

  install    Install/update and load the daily 00:05 LaunchAgent (default).
  uninstall  Unload the LaunchAgent and remove its installed runtime files.
             Existing synchronization logs and Git caches are retained.
  status     Show whether the LaunchAgent and runtime files are installed.
EOF
}

cleanup() {
	if [[ -n "$TEMP_PLIST" ]]; then
		rm -f "$TEMP_PLIST"
	fi
}
trap cleanup EXIT HUP INT TERM

if [[ $# -gt 1 ]]; then
	usage >&2
	exit 2
fi

case "$ACTION" in
	-h|--help|help)
		usage
		exit 0
		;;
	status)
		if [[ -f "$AGENT_PATH" ]]; then
			echo "LaunchAgent file: installed (${AGENT_PATH})"
		else
			echo "LaunchAgent file: not installed (${AGENT_PATH})"
		fi
		if [[ -x "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.sh" && -x "$RUNNER_PATH" && -r "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.repos" ]]; then
			echo "Runtime files: installed (${RUNTIME_DIR})"
		else
			echo "Runtime files: incomplete or not installed (${RUNTIME_DIR})"
		fi
		if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
			echo "LaunchAgent state: loaded"
			exit 0
		fi
		echo "LaunchAgent state: not loaded"
		exit 1
		;;
	uninstall)
		launchctl bootout "$DOMAIN" "$AGENT_PATH" 2>/dev/null || true
		launchctl disable "${DOMAIN}/${LABEL}" 2>/dev/null || true
		rm -f "$AGENT_PATH"
		rm -f "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.sh"
		rm -f "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.repos"
		rm -f "$RUNNER_PATH"
		rmdir "$RUNTIME_LAUNCHD_DIR" 2>/dev/null || true
		rmdir "$RUNTIME_DIR" 2>/dev/null || true
		echo "Uninstalled LaunchAgent: ${LABEL}"
		echo "Retained logs: ${LAUNCHD_LOG_DIR}"
		echo "Retained incremental cache: ${EXTERNAL_CACHE_ROOT}"
		exit 0
		;;
	install)
		;;
	*)
		echo "Unknown action: ${ACTION}" >&2
		usage >&2
		exit 2
		;;
esac

TEMP_PLIST="$(mktemp "${TMPDIR:-/tmp}/zhanlu-git-sync-plist.XXXXXX")"
mkdir -p "$RUNTIME_LAUNCHD_DIR" "$AGENT_DIR" "$LAUNCHD_LOG_DIR"
/usr/bin/install -m 0755 "${SYNC_DIR}/sync-zhanlu-gitlab-to-github.sh" "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.sh"
/usr/bin/install -m 0644 "${SYNC_DIR}/sync-zhanlu-gitlab-to-github.repos" "${RUNTIME_DIR}/sync-zhanlu-gitlab-to-github.repos"
/usr/bin/install -m 0755 "${SCRIPT_DIR}/run-zhanlu-gitlab-to-github-sync.sh" "$RUNNER_PATH"

/usr/bin/install -m 0644 "$PLIST_TEMPLATE" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 ${RUNNER_PATH}" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath ${LAUNCHD_LOG_DIR}/launchd.stdout.log" "$TEMP_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${LAUNCHD_LOG_DIR}/launchd.stderr.log" "$TEMP_PLIST"
plutil -lint "$TEMP_PLIST"

launchctl bootout "$DOMAIN" "$AGENT_PATH" 2>/dev/null || true
/usr/bin/install -m 0644 "$TEMP_PLIST" "$AGENT_PATH"
launchctl enable "${DOMAIN}/${LABEL}"
launchctl bootstrap "$DOMAIN" "$AGENT_PATH"

echo "Installed runtime: ${RUNTIME_DIR}"
echo "Installed LaunchAgent: ${AGENT_PATH}"
echo "Schedule: every day at 00:05 local time"
