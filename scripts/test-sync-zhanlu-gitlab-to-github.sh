#!/usr/bin/env bash
# Isolated integration tests for sync-zhanlu-gitlab-to-github.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-zhanlu-gitlab-to-github.sh"
SELECTED_SYNC_SCRIPT="${SCRIPT_DIR}/sync-zhanlu-selected-refs.sh"
RUNNER_SCRIPT="${SCRIPT_DIR}/launchd/run-zhanlu-gitlab-to-github-sync.sh"
INSTALLER_SCRIPT="${SCRIPT_DIR}/launchd/install-zhanlu-gitlab-to-github-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zhanlu-git-sync-test.XXXXXX")"
SOURCE_BARE="${TEST_ROOT}/source.git"
GITHUB_BARE="${TEST_ROOT}/github.git"
WORK="${TEST_ROOT}/work"
GITHUB_WORK="${TEST_ROOT}/github-work"
TMP_ROOT="${TEST_ROOT}/tmp"
CACHE_ROOT="${TEST_ROOT}/cache"
LOCK_ROOT="${TEST_ROOT}/lock-root"
LOG_DIR="${TEST_ROOT}/logs"
CONFIG_FILE="${TEST_ROOT}/repos.tsv"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_ref_equal() {
	local left_repo="$1"
	local left_ref="$2"
	local right_repo="$3"
	local right_ref="$4"
	local left_sha right_sha
	left_sha="$(git --git-dir="$left_repo" rev-parse "$left_ref")"
	right_sha="$(git --git-dir="$right_repo" rev-parse "$right_ref")"
	[[ "$left_sha" == "$right_sha" ]] || fail "${left_ref} (${left_sha}) != ${right_ref} (${right_sha})"
}

assert_ref_exists() {
	git --git-dir="$1" rev-parse -q --verify "$2" >/dev/null || fail "missing ref $2"
}

assert_ref_missing() {
	if git --git-dir="$1" rev-parse -q --verify "$2" >/dev/null 2>&1; then
		fail "unexpected ref $2"
	fi
}

assert_ref_unchanged() {
	local repo="$1"
	local ref="$2"
	local expected="$3"
	local actual
	actual="$(git --git-dir="$repo" rev-parse "$ref")"
	[[ "$actual" == "$expected" ]] || fail "${ref} changed: expected ${expected}, got ${actual}"
}

git init --bare "$SOURCE_BARE" >/dev/null
git init --bare "$GITHUB_BARE" >/dev/null
git init -b develop "$WORK" >/dev/null
git -C "$WORK" config user.name test
git -C "$WORK" config user.email test@example.com
echo base >"${WORK}/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" commit -m base >/dev/null
BASE_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" remote add source "$SOURCE_BARE"
git -C "$WORK" remote add github "$GITHUB_BARE"
git -C "$WORK" push source develop >/dev/null
git -C "$WORK" push github develop >/dev/null

git -C "$WORK" branch github-only "$BASE_SHA"
git -C "$WORK" push github github-only >/dev/null
git -C "$WORK" tag github-only-tag "$BASE_SHA"
git -C "$WORK" push github github-only-tag >/dev/null
git -C "$WORK" tag tag-conflict "$BASE_SHA"
git -C "$WORK" push github tag-conflict >/dev/null

echo gitlab-default >>"${WORK}/file.txt"
git -C "$WORK" commit -am gitlab-default >/dev/null
SOURCE_DEFAULT_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" push source develop >/dev/null
git -C "$WORK" tag source-tag
git -C "$WORK" push source source-tag >/dev/null
git -C "$WORK" tag -f tag-conflict >/dev/null
git -C "$WORK" push source tag-conflict >/dev/null

git -C "$WORK" checkout -b feature-new "$BASE_SHA" >/dev/null
echo new >"${WORK}/new.txt"
git -C "$WORK" add new.txt
git -C "$WORK" commit -m feature-new >/dev/null
git -C "$WORK" push source feature-new >/dev/null

git -C "$WORK" checkout -b feature-ff "$BASE_SHA" >/dev/null
echo ff1 >"${WORK}/ff.txt"
git -C "$WORK" add ff.txt
git -C "$WORK" commit -m ff1 >/dev/null
git -C "$WORK" push source feature-ff >/dev/null
git -C "$WORK" push github feature-ff >/dev/null
echo ff2 >>"${WORK}/ff.txt"
git -C "$WORK" commit -am ff2 >/dev/null
git -C "$WORK" push source feature-ff >/dev/null
GITHUB_FF_BEFORE_DEFAULT="$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/feature-ff)"

git -C "$WORK" checkout -b feature-ahead "$BASE_SHA" >/dev/null
echo common >"${WORK}/ahead.txt"
git -C "$WORK" add ahead.txt
git -C "$WORK" commit -m ahead-common >/dev/null
git -C "$WORK" push source feature-ahead >/dev/null
git -C "$WORK" push github feature-ahead >/dev/null

git clone "$GITHUB_BARE" "$GITHUB_WORK" >/dev/null 2>&1
git -C "$GITHUB_WORK" config user.name test
git -C "$GITHUB_WORK" config user.email test@example.com
git -C "$GITHUB_WORK" checkout feature-ahead >/dev/null
echo github-ahead >>"${GITHUB_WORK}/ahead.txt"
git -C "$GITHUB_WORK" commit -am github-ahead >/dev/null
git -C "$GITHUB_WORK" push origin feature-ahead >/dev/null
GITHUB_AHEAD_SHA="$(git -C "$GITHUB_WORK" rev-parse HEAD)"

git -C "$WORK" checkout -b feature-diverged "$BASE_SHA" >/dev/null
echo source >"${WORK}/diverged.txt"
git -C "$WORK" add diverged.txt
git -C "$WORK" commit -m source-diverged >/dev/null
git -C "$WORK" push source feature-diverged >/dev/null

git -C "$GITHUB_WORK" checkout -b feature-diverged "$BASE_SHA" >/dev/null
echo github >"${GITHUB_WORK}/diverged.txt"
git -C "$GITHUB_WORK" add diverged.txt
git -C "$GITHUB_WORK" commit -m github-diverged >/dev/null
git -C "$GITHUB_WORK" push origin feature-diverged >/dev/null
GITHUB_DIVERGED_SHA="$(git -C "$GITHUB_WORK" rev-parse HEAD)"

git --git-dir="$SOURCE_BARE" symbolic-ref HEAD refs/heads/develop
git --git-dir="$GITHUB_BARE" symbolic-ref HEAD refs/heads/develop
printf 'fixture\t%s\t%s\tdevelop\n' "$SOURCE_BARE" "$GITHUB_BARE" >"$CONFIG_FILE"

set +e
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --repo fixture >"${TEST_ROOT}/sync.log" 2>&1
SYNC_STATUS=$?
set -e
[[ "$SYNC_STATUS" -eq 0 ]] || fail "expected default-only status 0, got ${SYNC_STATUS}"

assert_ref_equal "$SOURCE_BARE" refs/heads/develop "$GITHUB_BARE" refs/heads/develop
assert_ref_missing "$GITHUB_BARE" refs/heads/feature-new
assert_ref_unchanged "$GITHUB_BARE" refs/heads/feature-ff "$GITHUB_FF_BEFORE_DEFAULT"
assert_ref_missing "$GITHUB_BARE" refs/tags/source-tag
assert_ref_unchanged "$GITHUB_BARE" refs/tags/tag-conflict "$BASE_SHA"
assert_ref_exists "$GITHUB_BARE" refs/heads/github-only
assert_ref_exists "$GITHUB_BARE" refs/tags/github-only-tag
assert_ref_missing "${CACHE_ROOT}/fixture.git" refs/remotes/gitlab/feature-new
assert_ref_missing "${CACHE_ROOT}/fixture.git" refs/zhanlu-sync/gitlab-tags/source-tag
grep -q 'Ref scope: default branches only' "${TEST_ROOT}/sync.log" || fail "default-only scope was not reported"

set +e
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --all-refs --repo fixture >"${TEST_ROOT}/all-refs.log" 2>&1
ALL_REFS_STATUS=$?
set -e
[[ "$ALL_REFS_STATUS" -eq 1 ]] || fail "expected all-refs partial status 1, got ${ALL_REFS_STATUS}"

assert_ref_equal "$SOURCE_BARE" refs/heads/feature-new "$GITHUB_BARE" refs/heads/feature-new
assert_ref_equal "$SOURCE_BARE" refs/heads/feature-ff "$GITHUB_BARE" refs/heads/feature-ff
assert_ref_unchanged "$GITHUB_BARE" refs/heads/feature-ahead "$GITHUB_AHEAD_SHA"
assert_ref_unchanged "$GITHUB_BARE" refs/heads/feature-diverged "$GITHUB_DIVERGED_SHA"
assert_ref_exists "$GITHUB_BARE" refs/heads/github-only
assert_ref_exists "$GITHUB_BARE" refs/tags/github-only-tag
assert_ref_exists "$GITHUB_BARE" refs/tags/source-tag
assert_ref_unchanged "$GITHUB_BARE" refs/tags/tag-conflict "$BASE_SHA"
grep -q 'skipped conflicting/protected branch: feature-ahead' "${TEST_ROOT}/all-refs.log" || fail "ahead branch was not reported"
grep -q 'skipped conflicting/protected branch: feature-diverged' "${TEST_ROOT}/all-refs.log" || fail "diverged branch was not reported"
grep -q 'skipped conflicting tag: tag-conflict' "${TEST_ROOT}/all-refs.log" || fail "tag conflict was not reported"
grep -q 'Ref scope: all branches and tags' "${TEST_ROOT}/all-refs.log" || fail "all-refs scope was not reported"
[[ -d "${CACHE_ROOT}/fixture.git" ]] || fail "persistent bare cache was not retained"
touch "${CACHE_ROOT}/fixture.git/.cache-reuse-sentinel"

BEFORE_DRY_RUN="$(git --git-dir="$GITHUB_BARE" show-ref | LC_ALL=C sort)"
set +e
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --dry-run --all-refs --repo fixture >"${TEST_ROOT}/dry-run.log" 2>&1
DRY_STATUS=$?
set -e
[[ "$DRY_STATUS" -eq 1 ]] || fail "expected dry-run partial status 1, got ${DRY_STATUS}"
AFTER_DRY_RUN="$(git --git-dir="$GITHUB_BARE" show-ref | LC_ALL=C sort)"
[[ "$BEFORE_DRY_RUN" == "$AFTER_DRY_RUN" ]] || fail "dry-run changed GitHub refs"
[[ -f "${CACHE_ROOT}/fixture.git/.cache-reuse-sentinel" ]] || fail "persistent cache was recreated instead of reused"

# Portal builds synchronize only the three explicitly selected refs. Diverged
# branches and tags are overwritten with an exact force-with-lease; a raw SHA
# receives a content-addressed GitHub branch so Actions can fetch it.
SELECTED_CONFIG="${TEST_ROOT}/selected-repos.tsv"
printf 'fixture-branch\t%s\t%s\tdevelop\nfixture-tag\t%s\t%s\tdevelop\nfixture-sha\t%s\t%s\tdevelop\n' \
	"$SOURCE_BARE" "$GITHUB_BARE" "$SOURCE_BARE" "$GITHUB_BARE" "$SOURCE_BARE" "$GITHUB_BARE" >"$SELECTED_CONFIG"
SELECTED_PLAN="${TEST_ROOT}/selected-plan.tsv"
SELECTED_BEFORE="$(git --git-dir="$GITHUB_BARE" show-ref | LC_ALL=C sort)"
ZHANLU_SYNC_CONFIG="$SELECTED_CONFIG" \
ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SELECTED_SYNC_SCRIPT" --dry-run \
	--ref fixture-branch=feature-diverged \
	--ref fixture-tag=refs/tags/tag-conflict \
	--ref fixture-sha="$SOURCE_DEFAULT_SHA" \
	--output-plan "$SELECTED_PLAN" >"${TEST_ROOT}/selected-dry-run.log" 2>&1
SELECTED_AFTER_DRY="$(git --git-dir="$GITHUB_BARE" show-ref | LC_ALL=C sort)"
[[ "$SELECTED_BEFORE" == "$SELECTED_AFTER_DRY" ]] || fail "selected-ref dry-run changed GitHub refs"
[[ "$(wc -l <"$SELECTED_PLAN" | tr -d ' ')" -eq 3 ]] || fail "selected-ref plan did not contain three refs"
grep -q 'Ref scope: selected refs only' "${TEST_ROOT}/selected-dry-run.log" || fail "selected-ref scope was not reported"
if grep -q -- '--all-refs' "${TEST_ROOT}/selected-dry-run.log" "$SELECTED_PLAN"; then
	fail "selected-ref synchronization used --all-refs"
fi

ZHANLU_SYNC_CONFIG="$SELECTED_CONFIG" \
ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SELECTED_SYNC_SCRIPT" --apply-plan "$SELECTED_PLAN" >"${TEST_ROOT}/selected-apply.log" 2>&1
assert_ref_equal "$SOURCE_BARE" refs/heads/feature-diverged "$GITHUB_BARE" refs/heads/feature-diverged
assert_ref_equal "$SOURCE_BARE" refs/tags/tag-conflict "$GITHUB_BARE" refs/tags/tag-conflict
assert_ref_exists "$GITHUB_BARE" "refs/heads/zhanlu-build-sha/${SOURCE_DEFAULT_SHA}"
assert_ref_equal "$SOURCE_BARE" refs/heads/develop "$GITHUB_BARE" "refs/heads/zhanlu-build-sha/${SOURCE_DEFAULT_SHA}"

# A destination changed after dry-run must fail the exact lease instead of
# silently overwriting the concurrent GitHub update.
LEASE_CONFIG="${TEST_ROOT}/lease-repos.tsv"
printf 'fixture-lease\t%s\t%s\tdevelop\n' "$SOURCE_BARE" "$GITHUB_BARE" >"$LEASE_CONFIG"
LEASE_PLAN="${TEST_ROOT}/lease-plan.tsv"
ZHANLU_SYNC_CONFIG="$LEASE_CONFIG" ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" ZHANLU_SYNC_RETRIES=1 \
	"$SELECTED_SYNC_SCRIPT" --dry-run --ref fixture-lease=feature-ahead --output-plan "$LEASE_PLAN" >/dev/null
git -C "$GITHUB_WORK" checkout feature-ahead >/dev/null
echo concurrent >>"${GITHUB_WORK}/ahead.txt"
git -C "$GITHUB_WORK" commit -am concurrent >/dev/null
git -C "$GITHUB_WORK" push origin feature-ahead >/dev/null
GITHUB_CONCURRENT_SHA="$(git -C "$GITHUB_WORK" rev-parse HEAD)"
set +e
ZHANLU_SYNC_CONFIG="$LEASE_CONFIG" ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" ZHANLU_SYNC_RETRIES=1 \
	"$SELECTED_SYNC_SCRIPT" --apply-plan "$LEASE_PLAN" >"${TEST_ROOT}/lease-apply.log" 2>&1
LEASE_STATUS=$?
set -e
[[ "$LEASE_STATUS" -eq 1 ]] || fail "expected selected-ref lease failure 1, got ${LEASE_STATUS}"
assert_ref_unchanged "$GITHUB_BARE" refs/heads/feature-ahead "$GITHUB_CONCURRENT_SHA"
grep -q 'GitHub ref moved after dry-run' "${TEST_ROOT}/lease-apply.log" || fail "selected-ref lease movement was not reported"

# Ambiguous branch/tag names and missing refs fail before any write.
git -C "$WORK" branch ambiguous-ref "$BASE_SHA"
git -C "$WORK" push source refs/heads/ambiguous-ref >/dev/null
git -C "$WORK" tag ambiguous-ref "$SOURCE_DEFAULT_SHA"
git -C "$WORK" push source refs/tags/ambiguous-ref >/dev/null
set +e
ZHANLU_SYNC_CONFIG="$LEASE_CONFIG" ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" ZHANLU_SYNC_RETRIES=1 \
	"$SELECTED_SYNC_SCRIPT" --dry-run --ref fixture-lease=ambiguous-ref --output-plan "${TEST_ROOT}/ambiguous-plan.tsv" >"${TEST_ROOT}/ambiguous.log" 2>&1
AMBIGUOUS_STATUS=$?
ZHANLU_SYNC_CONFIG="$LEASE_CONFIG" ZHANLU_SYNC_EXTERNAL_TMP_ROOT="$TMP_ROOT" ZHANLU_SYNC_EXTERNAL_CACHE_ROOT="$CACHE_ROOT" ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" ZHANLU_SYNC_RETRIES=1 \
	"$SELECTED_SYNC_SCRIPT" --dry-run --ref fixture-lease=missing-ref --output-plan "${TEST_ROOT}/missing-plan.tsv" >"${TEST_ROOT}/missing.log" 2>&1
MISSING_STATUS=$?
set -e
[[ "$AMBIGUOUS_STATUS" -eq 1 ]] || fail "expected ambiguous selected ref status 1, got ${AMBIGUOUS_STATUS}"
[[ "$MISSING_STATUS" -eq 1 ]] || fail "expected missing selected ref status 1, got ${MISSING_STATUS}"
grep -q 'ambiguous GitLab ref' "${TEST_ROOT}/ambiguous.log" || fail "ambiguous selected ref was not explained"
grep -q 'GitLab ref does not exist' "${TEST_ROOT}/missing.log" || fail "missing selected ref was not explained"

set +e
ZHANLU_SYNC_VOLUME_ROOT="${TEST_ROOT}/missing-volume" \
ZHANLU_SYNC_DEFAULT_TMP_ROOT="${TEST_ROOT}/fallback-tmp" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --dry-run --repo fixture >"${TEST_ROOT}/fallback.log" 2>&1
MOUNT_STATUS=$?
set -e
[[ "$MOUNT_STATUS" -eq 0 ]] || fail "expected fallback status 0, got ${MOUNT_STATUS}"
grep -q '(system)' "${TEST_ROOT}/fallback.log" || fail "missing external volume did not use system fallback"
grep -q 'Ref scope: default branches only' "${TEST_ROOT}/fallback.log" || fail "fallback did not retain default-only scope"
find "${TEST_ROOT}/fallback-tmp" -mindepth 1 -maxdepth 1 -name 'run.*' -print -quit | grep -q . && fail "fallback temporary run directory leaked"

mkdir -p "${LOCK_ROOT}/lock"
echo "$$" >"${LOCK_ROOT}/lock/pid"
set +e
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
"$SYNC_SCRIPT" --repo fixture >/dev/null 2>&1
LOCK_STATUS=$?
set -e
[[ "$LOCK_STATUS" -eq 2 ]] || fail "expected lock status 2, got ${LOCK_STATUS}"
rm -f "${LOCK_ROOT}/lock/pid"
rmdir "${LOCK_ROOT}/lock"

printf 'broken\t%s\t%s\tdevelop\n' "${TEST_ROOT}/unavailable.git" "$GITHUB_BARE" >"${TEST_ROOT}/broken-repos.tsv"
set +e
ZHANLU_SYNC_CONFIG="${TEST_ROOT}/broken-repos.tsv" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --repo broken >/dev/null 2>&1
NETWORK_STATUS=$?
set -e
[[ "$NETWORK_STATUS" -eq 2 ]] || fail "expected network/source failure status 2, got ${NETWORK_STATUS}"
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'run.*' -print -quit | grep -q . && fail "failed run temporary directory leaked"

git -C "$WORK" checkout develop >/dev/null
echo auth-failure >>"${WORK}/file.txt"
git -C "$WORK" commit -am auth-failure >/dev/null
git -C "$WORK" push source develop >/dev/null
DEST_BEFORE_AUTH_FAILURE="$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/develop)"
cat >"${GITHUB_BARE}/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
echo "Authentication failed" >&2
exit 1
EOF
chmod +x "${GITHUB_BARE}/hooks/pre-receive"
set +e
ZHANLU_SYNC_CONFIG="$CONFIG_FILE" \
ZHANLU_SYNC_TMP_ROOT="$TMP_ROOT" \
ZHANLU_SYNC_CACHE_ROOT="$CACHE_ROOT" \
ZHANLU_SYNC_LOCK_ROOT="$LOCK_ROOT" \
ZHANLU_SYNC_RETRIES=1 \
"$SYNC_SCRIPT" --repo fixture >"${TEST_ROOT}/auth.log" 2>&1
AUTH_STATUS=$?
set -e
[[ "$AUTH_STATUS" -eq 2 ]] || fail "expected authentication status 2, got ${AUTH_STATUS}"
assert_ref_unchanged "$GITHUB_BARE" refs/heads/develop "$DEST_BEFORE_AUTH_FAILURE"
grep -q 'authentication/authorization failed' "${TEST_ROOT}/auth.log" || fail "authentication failure was not reported"
rm -f "${GITHUB_BARE}/hooks/pre-receive"

old_log="${LOG_DIR}/run-20000101-000000.log"
mkdir -p "$LOG_DIR"
touch -t 200001010000 "$old_log"
fake_sync="${TEST_ROOT}/fake-sync.sh"
cat >"$fake_sync" <<'EOF'
#!/usr/bin/env bash
echo fake-success
exit 0
EOF
chmod +x "$fake_sync"
ZHANLU_SYNC_SCRIPT="$fake_sync" \
ZHANLU_SYNC_VOLUME_ROOT="${TEST_ROOT}/missing-volume" \
ZHANLU_SYNC_DEFAULT_LOG_DIR="$LOG_DIR" \
ZHANLU_SYNC_DISABLE_NOTIFICATIONS=1 \
"$RUNNER_SCRIPT"
[[ ! -e "$old_log" ]] || fail "old log was not removed"
find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'run.*' -print -quit | grep -q . && fail "temporary run directory leaked"
grep -q -- '--force-with-lease=' "$SYNC_SCRIPT" || fail "default branch push is missing force-with-lease"
if rg -n 'git[ -]lfs|Git/LFS|LFS synchronization' "$SYNC_SCRIPT" "$RUNNER_SCRIPT"; then
	fail "Git LFS logic is still present"
fi
/bin/bash -n "$INSTALLER_SCRIPT"
grep -q '__ZHANLU_SYNC_RUNNER__' "${SCRIPT_DIR}/launchd/com.zhanlu.sync-origin-upstream.plist" || fail "plist runtime placeholder is missing"
grep -q '__ZHANLU_SYNC_STDERR__' "${SCRIPT_DIR}/launchd/com.zhanlu.sync-origin-upstream.plist" || fail "plist stderr placeholder is missing"

mkdir -p "${TEST_ROOT}/fakebin" "${TEST_ROOT}/home"
cat >"${TEST_ROOT}/fakebin/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_ROOT}/fakebin/launchctl"
HOME="${TEST_ROOT}/home" \
TMPDIR="${TEST_ROOT}" \
PATH="${TEST_ROOT}/fakebin:${PATH}" \
ZHANLU_SYNC_RUNTIME_DIR="${TEST_ROOT}/runtime" \
"$INSTALLER_SCRIPT" install >/dev/null
[[ -f "${TEST_ROOT}/home/Library/LaunchAgents/com.zhanlu.sync-origin-upstream.plist" ]] || fail "installer did not create plist"
[[ -x "${TEST_ROOT}/runtime/sync-zhanlu-gitlab-to-github.sh" ]] || fail "installer did not copy runtime"
HOME="${TEST_ROOT}/home" \
TMPDIR="${TEST_ROOT}" \
PATH="${TEST_ROOT}/fakebin:${PATH}" \
ZHANLU_SYNC_RUNTIME_DIR="${TEST_ROOT}/runtime" \
"$INSTALLER_SCRIPT" status >/dev/null
HOME="${TEST_ROOT}/home" \
TMPDIR="${TEST_ROOT}" \
PATH="${TEST_ROOT}/fakebin:${PATH}" \
ZHANLU_SYNC_RUNTIME_DIR="${TEST_ROOT}/runtime" \
"$INSTALLER_SCRIPT" uninstall >/dev/null
[[ ! -e "${TEST_ROOT}/home/Library/LaunchAgents/com.zhanlu.sync-origin-upstream.plist" ]] || fail "uninstaller retained plist"
[[ ! -e "${TEST_ROOT}/runtime/sync-zhanlu-gitlab-to-github.sh" ]] || fail "uninstaller retained runtime"

echo "PASS: sync integration tests"
