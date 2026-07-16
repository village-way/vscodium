#!/usr/bin/env bash
# Synchronize Zhanlu GitLab repositories to GitHub without touching local worktrees.
#
# Usage:
#   ./scripts/sync-zhanlu-gitlab-to-github.sh [--dry-run] [--repo NAME] [--all-refs]
#
# The external volume keeps incremental bare repositories between runs. If it
# is unavailable, one run uses disposable bare repositories on the system disk.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ZHANLU_SYNC_CONFIG:-${SCRIPT_DIR}/sync-zhanlu-gitlab-to-github.repos}"
VOLUME_ROOT="${ZHANLU_SYNC_VOLUME_ROOT:-/Volumes/Files}"
EXTERNAL_STATE_ROOT="${ZHANLU_SYNC_EXTERNAL_STATE_ROOT:-${VOLUME_ROOT}/.zhanlu-git-sync}"
EXTERNAL_TMP_ROOT="${ZHANLU_SYNC_EXTERNAL_TMP_ROOT:-${EXTERNAL_STATE_ROOT}/tmp}"
EXTERNAL_CACHE_ROOT="${ZHANLU_SYNC_EXTERNAL_CACHE_ROOT:-${EXTERNAL_STATE_ROOT}/cache}"
DEFAULT_TMP_ROOT="${ZHANLU_SYNC_DEFAULT_TMP_ROOT:-${TMPDIR:-/tmp}/zhanlu-git-sync-$(id -u)}"
LOCK_ROOT="${ZHANLU_SYNC_LOCK_ROOT:-${TMPDIR:-/tmp}/zhanlu-git-sync-lock-$(id -u)}"
LOCK_DIR="${LOCK_ROOT}/lock"
RETRIES="${ZHANLU_SYNC_RETRIES:-3}"
RETRY_DELAY="${ZHANLU_SYNC_RETRY_DELAY:-5}"

DRY_RUN=0
ALL_REFS=0
SELECTED_REPO=""
RUN_DIR=""
CACHE_ROOT=""
CACHE_PERSISTENT=0
TEMP_LOCATION=""
LOCK_HELD=0
TOTAL_CHANGED=0
TOTAL_UNCHANGED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

usage() {
	cat <<'EOF'
Usage: sync-zhanlu-gitlab-to-github.sh [options]

Options:
  --dry-run       Fetch source metadata and preview Git pushes without writing GitHub.
  --repo NAME     Synchronize only one configured repository.
  --all-refs      Also synchronize non-default branches and tags.
                  Without this option, only each repository's default branch is fetched.
  -h, --help      Show this help.

Exit codes:
  0  All selected repositories synchronized without conflicts.
  1  One or more refs were skipped or a repository partially failed.
  2  Configuration, authentication prerequisite, temporary storage, or lock error.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--all-refs)
			ALL_REFS=1
			shift
			;;
		--repo)
			if [[ $# -lt 2 || -z "$2" ]]; then
				echo "--repo requires a repository name" >&2
				exit 2
			fi
			SELECTED_REPO="$2"
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

cleanup() {
	local exit_code=$?
	if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
		rm -rf "$RUN_DIR"
	fi
	if [[ "$LOCK_HELD" -eq 1 && -d "$LOCK_DIR" ]]; then
		rm -f "$LOCK_DIR/pid"
		rmdir "$LOCK_DIR" 2>/dev/null || true
	fi
	exit "$exit_code"
}

trap cleanup EXIT HUP INT TERM

is_mounted_volume() {
	if [[ "${ZHANLU_SYNC_SKIP_MOUNT_CHECK:-0}" == "1" ]]; then
		return 0
	fi
	mount | grep -F " on ${VOLUME_ROOT} (" >/dev/null 2>&1
}

create_run_dir() {
	local root="$1"
	local location="$2"
	if ! mkdir -p "$root" 2>/dev/null; then
		return 1
	fi
	if ! RUN_DIR="$(mktemp -d "${root}/run.XXXXXX" 2>/dev/null)"; then
		return 1
	fi
	TEMP_LOCATION="$location"
	return 0
}

can_use_directory() {
	local directory="$1"
	local probe=""
	if ! mkdir -p "$directory" 2>/dev/null; then
		return 1
	fi
	if ! probe="$(mktemp "${directory}/.write-test.XXXXXX" 2>/dev/null)"; then
		return 1
	fi
	rm -f "$probe"
	return 0
}

prepare_external_storage() {
	if [[ ! -d "$VOLUME_ROOT" ]] || ! is_mounted_volume; then
		return 1
	fi
	if ! create_run_dir "$EXTERNAL_TMP_ROOT" "external-persistent-cache"; then
		return 1
	fi
	if ! can_use_directory "$EXTERNAL_CACHE_ROOT"; then
		rm -rf -- "$RUN_DIR"
		RUN_DIR=""
		return 1
	fi
	CACHE_ROOT="$EXTERNAL_CACHE_ROOT"
	CACHE_PERSISTENT=1
	return 0
}

prepare_runtime() {
	local command_name
	for command_name in git mktemp; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			echo "Required command is unavailable: ${command_name}" >&2
			return 2
		fi
	done

	if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
		echo "Repository configuration is not readable: ${CONFIG_FILE}" >&2
		return 2
	fi
	if [[ -n "${ZHANLU_SYNC_TMP_ROOT:-}" ]]; then
		if ! create_run_dir "$ZHANLU_SYNC_TMP_ROOT" "configured"; then
			echo "Failed to create a temporary run directory under ${ZHANLU_SYNC_TMP_ROOT}" >&2
			return 2
		fi
		if [[ -n "${ZHANLU_SYNC_CACHE_ROOT:-}" ]]; then
			if ! can_use_directory "$ZHANLU_SYNC_CACHE_ROOT"; then
				echo "Failed to prepare configured cache directory: ${ZHANLU_SYNC_CACHE_ROOT}" >&2
				return 2
			fi
			CACHE_ROOT="$ZHANLU_SYNC_CACHE_ROOT"
			CACHE_PERSISTENT=1
		fi
	elif prepare_external_storage; then
		:
	elif ! create_run_dir "$DEFAULT_TMP_ROOT" "system"; then
		echo "Failed to create a temporary run directory under ${DEFAULT_TMP_ROOT}" >&2
		return 2
	fi
	if [[ -z "$CACHE_ROOT" ]]; then
		CACHE_ROOT="${RUN_DIR}/repos"
	fi
	if ! mkdir -p "$CACHE_ROOT"; then
		echo "Failed to prepare disposable repository storage: ${CACHE_ROOT}" >&2
		return 2
	fi

	if ! mkdir -p "$LOCK_ROOT"; then
		echo "Failed to prepare lock directory: ${LOCK_ROOT}" >&2
		return 2
	fi
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo "$$" >"${LOCK_DIR}/pid"
		LOCK_HELD=1
		return 0
	fi

	local old_pid=""
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		old_pid="$(sed -n '1p' "${LOCK_DIR}/pid" 2>/dev/null || true)"
	fi
	if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
		echo "Another synchronization process is active (pid ${old_pid})" >&2
		return 2
	fi

	rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
	if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
		echo "Unable to recover stale lock: ${LOCK_DIR}" >&2
		return 2
	fi
	echo "$$" >"${LOCK_DIR}/pid"
	LOCK_HELD=1
}

retry_cmd() {
	local label="$1"
	shift
	local attempt=1
	local delay="$RETRY_DELAY"
	local exit_code=0

	while [[ "$attempt" -le "$RETRIES" ]]; do
		"$@"
		exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			return 0
		fi
		if [[ "$attempt" -ge "$RETRIES" ]]; then
			break
		fi
		echo "${label}: attempt ${attempt}/${RETRIES} failed (exit ${exit_code}); retrying in ${delay}s" >&2
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done

	echo "${label}: failed after ${RETRIES} attempt(s)" >&2
	return 1
}

retry_to_file() {
	local output_file="$1"
	local label="$2"
	shift 2
	local attempt=1
	local delay="$RETRY_DELAY"
	local temp_file="${RUN_DIR}/capture.$$.${RANDOM}"
	local exit_code=0

	while [[ "$attempt" -le "$RETRIES" ]]; do
		: >"$temp_file"
		"$@" >"$temp_file"
		exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			mv "$temp_file" "$output_file"
			return 0
		fi
		if [[ "$attempt" -ge "$RETRIES" ]]; then
			break
		fi
		echo "${label}: attempt ${attempt}/${RETRIES} failed (exit ${exit_code}); retrying in ${delay}s" >&2
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done

	rm -f "$temp_file"
	echo "${label}: failed after ${RETRIES} attempt(s)" >&2
	return 1
}

remote_sha_for_ref() {
	local refs_file="$1"
	local ref_name="$2"
	awk -v target="$ref_name" '$2 == target { print $1; exit }' "$refs_file"
}

configure_cache() {
	local cache_dir="$1"
	local gitlab_url="$2"
	local github_url="$3"

	if [[ ! -d "$cache_dir" ]]; then
		if ! git init --bare "$cache_dir" >/dev/null; then
			return 1
		fi
	elif ! git --git-dir="$cache_dir" rev-parse --is-bare-repository >/dev/null 2>&1; then
		echo "Cache is not a bare Git repository: ${cache_dir}" >&2
		return 1
	fi

	if [[ "$CACHE_PERSISTENT" -eq 1 ]]; then
		git --git-dir="$cache_dir" config --unset gc.auto 2>/dev/null || true
	else
		git --git-dir="$cache_dir" config gc.auto 0
	fi
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

push_ref() {
	local cache_dir="$1"
	local output_file="$2"
	local force_lease="$3"
	local source_ref="$4"
	local destination_ref="$5"
	local args=(push --porcelain --no-verify)
	local attempt=1
	local delay="$RETRY_DELAY"
	local exit_code=0

	if [[ "$DRY_RUN" -eq 1 ]]; then
		args+=(--dry-run)
	fi
	if [[ -n "$force_lease" ]]; then
		args+=("$force_lease")
	fi
	args+=(github "${source_ref}:${destination_ref}")

	while [[ "$attempt" -le "$RETRIES" ]]; do
		git --git-dir="$cache_dir" "${args[@]}" >"$output_file" 2>&1
		exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			return 0
		fi
		if is_skippable_rejection "$output_file" || is_authentication_failure "$output_file" || [[ "$attempt" -ge "$RETRIES" ]]; then
			return "$exit_code"
		fi
		echo "GitHub push: attempt ${attempt}/${RETRIES} failed (exit ${exit_code}); retrying in ${delay}s" >&2
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
	return "$exit_code"
}

is_skippable_rejection() {
	local output_file="$1"
	grep -Eiq 'non-fast-forward|fetch first|remote rejected|protected branch|GH006|GH013|cannot lock ref|stale info' "$output_file"
}

is_authentication_failure() {
	local output_file="$1"
	grep -Eiq 'authentication failed|could not read (Username|Password)|permission denied|access denied|repository not found|terminal prompts disabled|HTTP (401|403)|publickey' "$output_file"
}

push_batch() {
	local cache_dir="$1"
	local output_file="$2"
	shift 2
	local args=(push --porcelain --no-verify)
	local attempt=1
	local delay="$RETRY_DELAY"
	local exit_code=0

	if [[ "$DRY_RUN" -eq 1 ]]; then
		args+=(--dry-run)
	fi
	args+=(github)
	args+=("$@")

	while [[ "$attempt" -le "$RETRIES" ]]; do
		git --git-dir="$cache_dir" "${args[@]}" >"$output_file" 2>&1
		exit_code=$?
		if [[ "$exit_code" -eq 0 ]]; then
			return 0
		fi
		if is_skippable_rejection "$output_file" || is_authentication_failure "$output_file" || [[ "$attempt" -ge "$RETRIES" ]]; then
			return "$exit_code"
		fi
		echo "GitHub batch push: attempt ${attempt}/${RETRIES} failed (exit ${exit_code}); retrying in ${delay}s" >&2
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
	return "$exit_code"
}

sync_repository() {
	local repo_name="$1"
	local gitlab_url="$2"
	local github_url="$3"
	local default_branch="$4"
	local cache_dir="${CACHE_ROOT}/${repo_name}.git"
	local heads_file="${RUN_DIR}/${repo_name}.github-heads"
	local tags_file="${RUN_DIR}/${repo_name}.github-tags"
	local push_output="${RUN_DIR}/${repo_name}.push-output"
	local batch_manifest="${RUN_DIR}/${repo_name}.batch-manifest"
	local source_ref=""
	local destination_ref=""
	local source_sha=""
	local destination_sha=""
	local branch=""
	local tag=""
	local lease_arg=""
	local repo_changed=0
	local repo_unchanged=0
	local repo_skipped=0
	local repo_failed=0
	local batch_status=0
	local ref_type=""
	local ref_name=""
	local result_line=""
	local batch_refspecs=()

	echo "[${repo_name}] start"
	if ! configure_cache "$cache_dir" "$gitlab_url" "$github_url"; then
		echo "[${repo_name}] failed to prepare cache" >&2
		TOTAL_FAILED=$((TOTAL_FAILED + 1))
		return 2
	fi

	if [[ "$ALL_REFS" -eq 1 ]]; then
		if ! retry_cmd "[${repo_name}] GitLab fetch" \
			git --git-dir="$cache_dir" fetch --atomic --prune --no-tags gitlab \
			'+refs/heads/*:refs/remotes/gitlab/*' \
			'+refs/tags/*:refs/zhanlu-sync/gitlab-tags/*'; then
			TOTAL_FAILED=$((TOTAL_FAILED + 1))
			return 2
		fi
	else
		if ! retry_cmd "[${repo_name}] GitLab default branch fetch" \
			git --git-dir="$cache_dir" fetch --atomic --no-tags gitlab \
			"+refs/heads/${default_branch}:refs/remotes/gitlab/${default_branch}"; then
			TOTAL_FAILED=$((TOTAL_FAILED + 1))
			return 2
		fi
	fi

	if ! git --git-dir="$cache_dir" rev-parse -q --verify "refs/remotes/gitlab/${default_branch}" >/dev/null 2>&1; then
		echo "[${repo_name}] GitLab default branch is missing: ${default_branch}" >&2
		TOTAL_FAILED=$((TOTAL_FAILED + 1))
		return 2
	fi
	if ! git --git-dir="$cache_dir" symbolic-ref HEAD "refs/remotes/gitlab/${default_branch}"; then
		echo "[${repo_name}] failed to set cache HEAD: ${default_branch}" >&2
		TOTAL_FAILED=$((TOTAL_FAILED + 1))
		return 2
	fi

	if [[ "$ALL_REFS" -eq 1 ]]; then
		if ! retry_to_file "$heads_file" "[${repo_name}] GitHub heads" git ls-remote --heads "$github_url"; then
			TOTAL_FAILED=$((TOTAL_FAILED + 1))
			return 2
		fi
	else
		if ! retry_to_file "$heads_file" "[${repo_name}] GitHub default branch" git ls-remote "$github_url" "refs/heads/${default_branch}"; then
			TOTAL_FAILED=$((TOTAL_FAILED + 1))
			return 2
		fi
	fi
	if [[ "$ALL_REFS" -eq 1 ]] && ! retry_to_file "$tags_file" "[${repo_name}] GitHub tags" git ls-remote --tags "$github_url"; then
		TOTAL_FAILED=$((TOTAL_FAILED + 1))
		return 2
	fi

	source_ref="refs/remotes/gitlab/${default_branch}"
	destination_ref="refs/heads/${default_branch}"
	source_sha="$(git --git-dir="$cache_dir" rev-parse "$source_ref")"
	destination_sha="$(remote_sha_for_ref "$heads_file" "$destination_ref")"
	if [[ "$source_sha" == "$destination_sha" ]]; then
		echo "[${repo_name}] unchanged default branch: ${default_branch}"
		repo_unchanged=$((repo_unchanged + 1))
	else
		lease_arg="--force-with-lease=${destination_ref}:${destination_sha}"
		if push_ref "$cache_dir" "$push_output" "$lease_arg" "$source_ref" "$destination_ref"; then
			cat "$push_output"
			echo "[${repo_name}] synchronized default branch: ${default_branch}"
			repo_changed=$((repo_changed + 1))
		else
			cat "$push_output" >&2
			if is_authentication_failure "$push_output"; then
				echo "[${repo_name}] GitHub authentication/authorization failed" >&2
				TOTAL_FAILED=$((TOTAL_FAILED + 1))
				return 2
			fi
			echo "[${repo_name}] failed default branch lease: ${default_branch}" >&2
			repo_failed=$((repo_failed + 1))
		fi
	fi

	if [[ "$ALL_REFS" -eq 0 ]]; then
		TOTAL_CHANGED=$((TOTAL_CHANGED + repo_changed))
		TOTAL_UNCHANGED=$((TOTAL_UNCHANGED + repo_unchanged))
		TOTAL_FAILED=$((TOTAL_FAILED + repo_failed))
		echo "[${repo_name}] summary: changed=${repo_changed} unchanged=${repo_unchanged} skipped=0 failed=${repo_failed}"
		if [[ "$repo_failed" -gt 0 ]]; then
			return 1
		fi
		return 0
	fi

	: >"$batch_manifest"
	while IFS= read -r branch; do
		[[ -n "$branch" ]] || continue
		[[ "$branch" == "$default_branch" ]] && continue
		source_ref="refs/remotes/gitlab/${branch}"
		destination_ref="refs/heads/${branch}"
		source_sha="$(git --git-dir="$cache_dir" rev-parse "$source_ref")"
		destination_sha="$(remote_sha_for_ref "$heads_file" "$destination_ref")"
		if [[ "$source_sha" == "$destination_sha" ]]; then
			repo_unchanged=$((repo_unchanged + 1))
			continue
		fi
		batch_refspecs+=("${source_ref}:${destination_ref}")
		printf 'branch\t%s\t%s\n' "$branch" "$destination_ref" >>"$batch_manifest"
	done < <(git --git-dir="$cache_dir" for-each-ref --format='%(refname:strip=3)' refs/remotes/gitlab | LC_ALL=C sort)

	while IFS= read -r tag; do
		[[ -n "$tag" ]] || continue
		source_ref="refs/zhanlu-sync/gitlab-tags/${tag}"
		destination_ref="refs/tags/${tag}"
		source_sha="$(git --git-dir="$cache_dir" rev-parse "$source_ref")"
		destination_sha="$(remote_sha_for_ref "$tags_file" "$destination_ref")"
		if [[ "$source_sha" == "$destination_sha" ]]; then
			repo_unchanged=$((repo_unchanged + 1))
		elif [[ -n "$destination_sha" ]]; then
			echo "[${repo_name}] skipped conflicting tag: ${tag}" >&2
			repo_skipped=$((repo_skipped + 1))
		else
			batch_refspecs+=("${source_ref}:${destination_ref}")
			printf 'tag\t%s\t%s\n' "$tag" "$destination_ref" >>"$batch_manifest"
		fi
	done < <(git --git-dir="$cache_dir" for-each-ref --format='%(refname:strip=3)' refs/zhanlu-sync/gitlab-tags | LC_ALL=C sort)

	if [[ "${#batch_refspecs[@]}" -gt 0 ]]; then
		push_batch "$cache_dir" "$push_output" "${batch_refspecs[@]}" || batch_status=$?
		if [[ "$batch_status" -eq 0 ]]; then
			cat "$push_output"
		else
			cat "$push_output" >&2
			if is_authentication_failure "$push_output"; then
				echo "[${repo_name}] GitHub authentication/authorization failed" >&2
				repo_failed=$((repo_failed + 1))
				TOTAL_CHANGED=$((TOTAL_CHANGED + repo_changed))
				TOTAL_UNCHANGED=$((TOTAL_UNCHANGED + repo_unchanged))
				TOTAL_SKIPPED=$((TOTAL_SKIPPED + repo_skipped))
				TOTAL_FAILED=$((TOTAL_FAILED + repo_failed))
				echo "[${repo_name}] summary: changed=${repo_changed} unchanged=${repo_unchanged} skipped=${repo_skipped} failed=${repo_failed}"
				return 2
			fi
		fi

		while IFS=$'\t' read -r ref_type ref_name destination_ref; do
			result_line="$(grep -F ":${destination_ref}" "$push_output" | tail -1 || true)"
			if [[ -n "$result_line" && ! "$result_line" =~ ^! ]]; then
				echo "[${repo_name}] synchronized ${ref_type}: ${ref_name}"
				repo_changed=$((repo_changed + 1))
			elif [[ -n "$result_line" ]] && echo "$result_line" | grep -Eiq 'non-fast-forward|fetch first|remote rejected|protected branch|GH006|GH013|cannot lock ref|stale info'; then
				echo "[${repo_name}] skipped conflicting/protected ${ref_type}: ${ref_name}" >&2
				repo_skipped=$((repo_skipped + 1))
			else
				echo "[${repo_name}] failed ${ref_type}: ${ref_name}" >&2
				repo_failed=$((repo_failed + 1))
			fi
		done <"$batch_manifest"
	fi

	TOTAL_CHANGED=$((TOTAL_CHANGED + repo_changed))
	TOTAL_UNCHANGED=$((TOTAL_UNCHANGED + repo_unchanged))
	TOTAL_SKIPPED=$((TOTAL_SKIPPED + repo_skipped))
	TOTAL_FAILED=$((TOTAL_FAILED + repo_failed))
	echo "[${repo_name}] summary: changed=${repo_changed} unchanged=${repo_unchanged} skipped=${repo_skipped} failed=${repo_failed}"
	if [[ "$repo_skipped" -gt 0 || "$repo_failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main() {
	local selected_count=0
	local overall=0
	local repo_name=""
	local gitlab_url=""
	local github_url=""
	local default_branch=""

	if ! prepare_runtime; then
		exit 2
	fi
	if ! cd "$RUN_DIR"; then
		echo "Unable to enter temporary run directory: ${RUN_DIR}" >&2
		exit 2
	fi

	export GIT_TERMINAL_PROMPT=0
	export GIT_HTTP_LOW_SPEED_LIMIT="${ZHANLU_SYNC_HTTP_LOW_SPEED_LIMIT:-1}"
	export GIT_HTTP_LOW_SPEED_TIME="${ZHANLU_SYNC_HTTP_LOW_SPEED_TIME:-60}"
	export LC_ALL=C
	echo "Temporary storage: ${RUN_DIR} (${TEMP_LOCATION})"
	if [[ "$CACHE_PERSISTENT" -eq 1 ]]; then
		echo "Incremental cache: ${CACHE_ROOT} (persistent)"
	else
		echo "Incremental cache: ${CACHE_ROOT} (disposable)"
	fi
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "Mode: dry-run"
	else
		echo "Mode: apply"
	fi
	if [[ "$ALL_REFS" -eq 1 ]]; then
		echo "Ref scope: all branches and tags"
	else
		echo "Ref scope: default branches only"
	fi

	while IFS=$'\t' read -r repo_name gitlab_url github_url default_branch; do
		case "$repo_name" in
			""|\#*) continue ;;
		esac
		if [[ -n "$SELECTED_REPO" && "$repo_name" != "$SELECTED_REPO" ]]; then
			continue
		fi
		selected_count=$((selected_count + 1))
		if [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+$ || -z "$gitlab_url" || -z "$github_url" || -z "$default_branch" ]]; then
			echo "Invalid repository configuration for: ${repo_name}" >&2
			exit 2
		fi
		if ! git check-ref-format --branch "$default_branch" >/dev/null 2>&1; then
			echo "Invalid default branch for ${repo_name}: ${default_branch}" >&2
			exit 2
		fi
		local repo_status=0
		sync_repository "$repo_name" "$gitlab_url" "$github_url" "$default_branch" || repo_status=$?
		if [[ "$CACHE_PERSISTENT" -eq 1 ]]; then
			git --git-dir="${CACHE_ROOT:?}/${repo_name}.git" gc --auto --quiet 2>/dev/null || true
		else
			rm -rf -- "${CACHE_ROOT:?}/${repo_name}.git"
		fi
		if [[ "$repo_status" -eq 2 ]]; then
			overall=2
		elif [[ "$repo_status" -ne 0 && "$overall" -eq 0 ]]; then
			overall=1
		fi
	done <"$CONFIG_FILE"

	if [[ "$selected_count" -eq 0 ]]; then
		if [[ -n "$SELECTED_REPO" ]]; then
			echo "Repository is not configured: ${SELECTED_REPO}" >&2
		else
			echo "No repositories are configured in ${CONFIG_FILE}" >&2
		fi
		exit 2
	fi

	echo "Overall summary: changed=${TOTAL_CHANGED} unchanged=${TOTAL_UNCHANGED} skipped=${TOTAL_SKIPPED} failed=${TOTAL_FAILED}"
	if [[ "$TOTAL_SKIPPED" -gt 0 || "$TOTAL_FAILED" -gt 0 ]] && [[ "$overall" -eq 0 ]]; then
		overall=1
	fi
	exit "$overall"
}

main
