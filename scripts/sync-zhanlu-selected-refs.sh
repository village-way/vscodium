#!/usr/bin/env bash
# Synchronize an immutable list of explicitly selected GitLab refs to GitHub.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ZHANLU_SYNC_CONFIG:-${SCRIPT_DIR}/sync-zhanlu-gitlab-to-github.repos}"
TMP_ROOT="${ZHANLU_SYNC_EXTERNAL_TMP_ROOT:-${TMPDIR:-/tmp}/zhanlu-selected-ref-sync-$(id -u)}"
CACHE_ROOT="${ZHANLU_SYNC_EXTERNAL_CACHE_ROOT:-${TMP_ROOT}/cache}"
LOCK_ROOT="${ZHANLU_SYNC_LOCK_ROOT:-${TMP_ROOT}/lock-root}"
LOCK_DIR="${LOCK_ROOT}/lock"
RETRIES="${ZHANLU_SYNC_RETRIES:-3}"
RETRY_DELAY="${ZHANLU_SYNC_RETRY_DELAY:-5}"

MODE=""
OUTPUT_PLAN=""
INPUT_PLAN=""
RUN_DIR=""
LOCK_HELD=0
SELECTED_REFS=()

usage() {
	cat <<'EOF'
Usage:
  sync-zhanlu-selected-refs.sh --dry-run --ref REPOSITORY=REF [...] --output-plan FILE
  sync-zhanlu-selected-refs.sh --apply-plan FILE

The dry-run resolves every selected GitLab ref, verifies the exact GitHub
force-with-lease push, and writes an immutable TSV plan. A repository may
appear more than once when the portal synchronizes develop plus a custom build
ref. Applying revalidates the GitLab source and GitHub lease before changing
only the planned refs.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run)
			MODE="dry-run"
			shift
			;;
		--ref)
			[[ $# -ge 2 && "$2" == *=* ]] || { echo "--ref requires REPOSITORY=REF" >&2; exit 2; }
			SELECTED_REFS+=("$2")
			shift 2
			;;
		--output-plan)
			[[ $# -ge 2 && -n "$2" ]] || { echo "--output-plan requires a file" >&2; exit 2; }
			OUTPUT_PLAN="$2"
			shift 2
			;;
		--apply-plan)
			MODE="apply"
			[[ $# -ge 2 && -n "$2" ]] || { echo "--apply-plan requires a file" >&2; exit 2; }
			INPUT_PLAN="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ "$MODE" == "dry-run" ]]; then
	[[ "${#SELECTED_REFS[@]}" -gt 0 && -n "$OUTPUT_PLAN" && -z "$INPUT_PLAN" ]] || { usage >&2; exit 2; }
elif [[ "$MODE" == "apply" ]]; then
	[[ -r "$INPUT_PLAN" && "${#SELECTED_REFS[@]}" -eq 0 && -z "$OUTPUT_PLAN" ]] || { usage >&2; exit 2; }
else
	usage >&2
	exit 2
fi

cleanup() {
	local status=$?
	if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
		rm -rf -- "$RUN_DIR"
	fi
	if [[ "$LOCK_HELD" -eq 1 && -d "$LOCK_DIR" ]]; then
		rm -f "$LOCK_DIR/pid"
		rmdir "$LOCK_DIR" 2>/dev/null || true
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

prepare_runtime() {
	local command_name old_pid=""
	for command_name in git mktemp awk sed; do
		command -v "$command_name" >/dev/null 2>&1 || { echo "Required command is unavailable: ${command_name}" >&2; return 2; }
	done
	[[ -r "$CONFIG_FILE" ]] || { echo "Repository configuration is not readable: ${CONFIG_FILE}" >&2; return 2; }
	mkdir -p "$TMP_ROOT" "$CACHE_ROOT" "$LOCK_ROOT" || return 2
	RUN_DIR="$(mktemp -d "${TMP_ROOT}/selected.XXXXXX")" || return 2
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo "$$" >"${LOCK_DIR}/pid"
		LOCK_HELD=1
		return 0
	fi
	[[ -f "${LOCK_DIR}/pid" ]] && old_pid="$(sed -n '1p' "${LOCK_DIR}/pid" 2>/dev/null || true)"
	if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
		echo "Another synchronization process is active (pid ${old_pid})" >&2
		return 2
	fi
	rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || return 2
	mkdir "$LOCK_DIR" || return 2
	echo "$$" >"${LOCK_DIR}/pid"
	LOCK_HELD=1
}

retry() {
	local label="$1"
	shift
	local attempt=1 delay="$RETRY_DELAY" status=0
	while [[ "$attempt" -le "$RETRIES" ]]; do
		"$@" && return 0
		status=$?
		[[ "$attempt" -ge "$RETRIES" ]] && break
		echo "${label}: attempt ${attempt}/${RETRIES} failed; retrying in ${delay}s" >&2
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
	echo "${label}: failed (${status})" >&2
	return "$status"
}

config_row() {
	local requested_repo="$1"
	awk -F '\t' -v repo="$requested_repo" '$1 == repo { print; found=1; exit } END { if (!found) exit 1 }' "$CONFIG_FILE"
}

configure_cache() {
	local repo="$1" gitlab_url="$2" github_url="$3" cache_dir="${CACHE_ROOT}/${repo}.git"
	if [[ ! -d "$cache_dir" ]]; then
		git init --bare "$cache_dir" >/dev/null || return 1
	fi
	git --git-dir="$cache_dir" rev-parse --is-bare-repository >/dev/null 2>&1 || return 1
	if git --git-dir="$cache_dir" remote get-url gitlab >/dev/null 2>&1; then
		git --git-dir="$cache_dir" remote set-url gitlab "$gitlab_url"
	else
		git --git-dir="$cache_dir" remote add gitlab "$gitlab_url"
	fi
	if git --git-dir="$cache_dir" remote get-url github >/dev/null 2>&1; then
		git --git-dir="$cache_dir" remote set-url github "$github_url"
	else
		git --git-dir="$cache_dir" remote add github "$github_url"
	fi
}

remote_sha() {
	local url="$1" ref="$2"
	git ls-remote "$url" "$ref" | awk -v target="$ref" '$2 == target { print $1; exit }'
}

resolve_selected_ref() {
	local repo="$1" requested="$2" gitlab_url="$3" cache_dir="${CACHE_ROOT}/${repo}.git"
	local type source_ref destination_ref source_object_sha source_commit_sha branch_sha tag_sha peeled_sha local_ref
	local_ref="refs/zhanlu-sync/selected/${repo}"

	if [[ "$requested" =~ ^[0-9a-fA-F]{40}$ ]]; then
		requested="$(printf '%s' "$requested" | tr 'A-F' 'a-f')"
		type="commit"
		source_ref="$requested"
		destination_ref="refs/heads/zhanlu-build-sha/${requested}"
	elif [[ "$requested" == refs/heads/* ]]; then
		type="branch"
		source_ref="$requested"
		destination_ref="$requested"
	elif [[ "$requested" == refs/tags/* ]]; then
		type="tag"
		source_ref="$requested"
		destination_ref="$requested"
	elif git check-ref-format --branch "$requested" >/dev/null 2>&1; then
		branch_sha="$(remote_sha "$gitlab_url" "refs/heads/${requested}")"
		tag_sha="$(remote_sha "$gitlab_url" "refs/tags/${requested}")"
		peeled_sha="$(remote_sha "$gitlab_url" "refs/tags/${requested}^{}")"
		if [[ -n "$branch_sha" && -n "$tag_sha" && "$branch_sha" != "${peeled_sha:-$tag_sha}" ]]; then
			echo "[${repo}] ambiguous GitLab ref '${requested}'; use refs/heads/ or refs/tags/" >&2
			return 1
		elif [[ -n "$branch_sha" ]]; then
			type="branch"; source_ref="refs/heads/${requested}"; destination_ref="$source_ref"
		elif [[ -n "$tag_sha" ]]; then
			type="tag"; source_ref="refs/tags/${requested}"; destination_ref="$source_ref"
		else
			echo "[${repo}] GitLab ref does not exist: ${requested}" >&2
			return 1
		fi
	else
		echo "[${repo}] invalid selected ref: ${requested}" >&2
		return 1
	fi

	git check-ref-format "$destination_ref" >/dev/null 2>&1 || { echo "[${repo}] invalid destination ref: ${destination_ref}" >&2; return 1; }
	retry "[${repo}] GitLab fetch ${requested}" git --git-dir="$cache_dir" fetch --force --no-tags gitlab "${source_ref}:${local_ref}" >/dev/null || return 1
	source_object_sha="$(git --git-dir="$cache_dir" rev-parse "$local_ref")"
	source_commit_sha="$(git --git-dir="$cache_dir" rev-parse "${local_ref}^{commit}" 2>/dev/null)" || {
		echo "[${repo}] selected ref is not a commit: ${requested}" >&2
		return 1
	}
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$type" "$requested" "$source_ref" "$destination_ref" "$source_object_sha" "$source_commit_sha" "$local_ref"
}

preview_selected_ref() {
	local repo="$1" type="$2" requested="$3" source_ref="$4" destination_ref="$5" source_object_sha="$6" source_commit_sha="$7" local_ref="$8" github_url="$9"
	local destination_sha action push_log="${RUN_DIR}/${repo}.push"
	destination_sha="$(remote_sha "$github_url" "$destination_ref")"
	if [[ "$destination_sha" == "$source_object_sha" ]]; then
		action="unchanged"
	else
		action="${destination_sha:+update}"
		[[ -n "$action" ]] || action="create"
		if ! git --git-dir="${CACHE_ROOT}/${repo}.git" push --porcelain --no-verify --dry-run "--force-with-lease=${destination_ref}:${destination_sha}" github "${local_ref}:${destination_ref}" >"$push_log" 2>&1; then
			cat "$push_log" >&2
			echo "[${repo}] selected ref dry-run failed: ${requested}" >&2
			return 1
		fi
	fi
	printf '[%s] %s %s: %s -> %s (%s)\n' "$repo" "$type" "$requested" "${destination_sha:-<missing>}" "$source_object_sha" "$action"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$type" "$requested" "$source_ref" "$destination_ref" "$source_object_sha" "$source_commit_sha" "${destination_sha:--}" "$action" >>"$OUTPUT_PLAN"
}

dry_run() {
	local entry repo requested row gitlab_url github_url default_branch resolved
	: >"$OUTPUT_PLAN"
	for entry in "${SELECTED_REFS[@]}"; do
		repo="${entry%%=*}"; requested="${entry#*=}"
		[[ -n "$repo" && -n "$requested" ]] || { echo "Invalid selected ref: ${entry}" >&2; return 1; }
		[[ "$(printf '%s\n' "${SELECTED_REFS[@]}" | awk -v selected="$entry" '$0 == selected { count++ } END { print count+0 }')" -eq 1 ]] || { echo "Duplicate selected repository/ref pair: ${entry}" >&2; return 1; }
		row="$(config_row "$repo")" || { echo "Repository is not configured: ${repo}" >&2; return 1; }
		IFS=$'\t' read -r _ gitlab_url github_url default_branch <<<"$row"
		configure_cache "$repo" "$gitlab_url" "$github_url" || return 2
		resolved="$(resolve_selected_ref "$repo" "$requested" "$gitlab_url")" || return 1
		IFS=$'\t' read -r repo type requested source_ref destination_ref source_object_sha source_commit_sha local_ref <<<"$resolved"
		preview_selected_ref "$repo" "$type" "$requested" "$source_ref" "$destination_ref" "$source_object_sha" "$source_commit_sha" "$local_ref" "$github_url" || return 1
	done
	[[ "$(awk 'END { print NR+0 }' "$OUTPUT_PLAN")" -eq "${#SELECTED_REFS[@]}" ]] || return 1
	echo "Selected ref dry-run completed: ${#SELECTED_REFS[@]} ref(s)"
}

apply_plan() {
	local repo type requested source_ref destination_ref planned_object_sha source_commit_sha planned_destination_sha action
	local row gitlab_url github_url default_branch resolved current_destination_sha local_ref push_log
	while IFS=$'\t' read -r repo type requested source_ref destination_ref planned_object_sha source_commit_sha planned_destination_sha action; do
		[[ -n "$repo" && -n "$destination_ref" && "$planned_object_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid selected-ref plan row" >&2; return 2; }
		[[ "$planned_destination_sha" == "-" ]] && planned_destination_sha=""
		row="$(config_row "$repo")" || { echo "Repository is not configured: ${repo}" >&2; return 2; }
		IFS=$'\t' read -r _ gitlab_url github_url default_branch <<<"$row"
		configure_cache "$repo" "$gitlab_url" "$github_url" || return 2
		resolved="$(resolve_selected_ref "$repo" "$requested" "$gitlab_url")" || return 1
		IFS=$'\t' read -r _ _ _ _ resolved_destination_ref resolved_object_sha resolved_commit_sha local_ref <<<"$resolved"
		if [[ "$resolved_destination_ref" != "$destination_ref" || "$resolved_object_sha" != "$planned_object_sha" || "$resolved_commit_sha" != "$source_commit_sha" ]]; then
			echo "[${repo}] GitLab ref moved after dry-run: ${requested}" >&2
			return 1
		fi
		current_destination_sha="$(remote_sha "$github_url" "$destination_ref")"
		if [[ "$current_destination_sha" == "$planned_object_sha" ]]; then
			echo "[${repo}] already applied ${type}: ${requested} (${source_commit_sha})"
			continue
		fi
		if [[ "$current_destination_sha" != "$planned_destination_sha" ]]; then
			echo "[${repo}] GitHub ref moved after dry-run: ${destination_ref}" >&2
			return 1
		fi
		push_log="${RUN_DIR}/${repo}.apply"
		if ! git --git-dir="${CACHE_ROOT}/${repo}.git" push --porcelain --no-verify "--force-with-lease=${destination_ref}:${planned_destination_sha}" github "${local_ref}:${destination_ref}" >"$push_log" 2>&1; then
			cat "$push_log" >&2
			echo "[${repo}] selected ref synchronization failed: ${requested}" >&2
			return 1
		fi
		cat "$push_log"
		echo "[${repo}] synchronized ${type}: ${requested} (${planned_destination_sha:-<missing>} -> ${planned_object_sha})"
	done <"$INPUT_PLAN"
	echo "Selected ref synchronization completed: $(awk 'END { print NR+0 }' "$INPUT_PLAN") ref(s)"
}

prepare_runtime || exit $?
export GIT_TERMINAL_PROMPT=0 LC_ALL=C
echo "Mode: ${MODE}"
echo "Ref scope: selected refs only"
if [[ "$MODE" == "dry-run" ]]; then
	dry_run
else
	apply_plan
fi
