# zhanlu_change - new file
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ZHANLU_REPO_URL="${ZHANLU_REPO_URL:-https://github.com/village-way/zhanlu-vs.git}"
ZHANLU_BRANCH="${ZHANLU_BRANCH:-dev_ide_core}"
ZHANLU_VS_REF="${ZHANLU_VS_REF:-}"
ZHANLU_DIR="${SCRIPT_DIR}/zhanlu-vs"
RELEASE_VERSION="${RELEASE_VERSION:-}"

if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "Error: RELEASE_VERSION is required"
  exit 1
fi

ZHANLU_CLI_VERSION="${RELEASE_VERSION%-insider}"

if [[ -n "${ZHANLU_GITHUB_TOKEN:-}" && "${ZHANLU_REPO_URL}" =~ ^https://github\.com ]]; then
  ZHANLU_REPO_URL="${ZHANLU_REPO_URL/https:\/\//https://${ZHANLU_GITHUB_TOKEN}@}"
  echo "Using GitHub token for zhanlu-vs authentication"
  git config --global credential.helper store
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/echo
fi

echo "=== Zhanlu CLI Compatibility Asset Builder ==="
if [[ "${ZHANLU_REPO_URL}" =~ ^https://.*@github\.com ]]; then
  DISPLAY_URL="${ZHANLU_REPO_URL/@*/@***}"
  echo "ZHANLU_REPO_URL: ${DISPLAY_URL}"
else
  echo "ZHANLU_REPO_URL: ${ZHANLU_REPO_URL}"
fi
echo "ZHANLU_BRANCH: ${ZHANLU_BRANCH}"
echo "ZHANLU_VS_REF: ${ZHANLU_VS_REF:-<default branch>}"
echo "ZHANLU_DIR: ${ZHANLU_DIR}"
echo "RELEASE_VERSION: ${RELEASE_VERSION}"
echo "KILO_VERSION: ${ZHANLU_CLI_VERSION}"

if [[ "${CI_BUILD:-}" != "no" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  git config --global --add safe.directory "${ZHANLU_DIR}" || true
  export GIT_TERMINAL_PROMPT=0
fi

if [[ "${GIT_LFS_FETCH:-}" != "1" ]]; then
  export GIT_LFS_SKIP_SMUDGE=1
  echo "Skipping LFS fetch (GIT_LFS_SKIP_SMUDGE=1)"
fi

if [[ "${ZHANLU_FORCE_CLONE:-}" == "yes" && -d "${ZHANLU_DIR}" ]]; then
  rm -rf "${ZHANLU_DIR}"
fi

if [[ -d "${ZHANLU_DIR}/.git" ]]; then
  echo "Updating existing zhanlu-vs checkout"
  git -C "${ZHANLU_DIR}" remote set-url origin "${ZHANLU_REPO_URL}"
  if [[ -n "${ZHANLU_VS_REF}" ]]; then
    git -C "${ZHANLU_DIR}" fetch --depth 1 origin "${ZHANLU_VS_REF}"
    git -C "${ZHANLU_DIR}" checkout --detach FETCH_HEAD
  else
    git -C "${ZHANLU_DIR}" fetch --depth 1 origin "${ZHANLU_BRANCH}"
    git -C "${ZHANLU_DIR}" checkout "${ZHANLU_BRANCH}" 2>/dev/null || git -C "${ZHANLU_DIR}" checkout -b "${ZHANLU_BRANCH}" "origin/${ZHANLU_BRANCH}"
    git -C "${ZHANLU_DIR}" reset --hard "origin/${ZHANLU_BRANCH}"
  fi
else
  echo "Cloning zhanlu-vs"
  mkdir -p "${ZHANLU_DIR}"
  git -C "${ZHANLU_DIR}" init -q
  git -C "${ZHANLU_DIR}" remote add origin "${ZHANLU_REPO_URL}"
  if [[ -n "${ZHANLU_VS_REF}" ]]; then
    git -C "${ZHANLU_DIR}" fetch --depth 1 origin "${ZHANLU_VS_REF}"
  else
    git -C "${ZHANLU_DIR}" fetch --depth 1 origin "${ZHANLU_BRANCH}"
  fi
  git -C "${ZHANLU_DIR}" checkout --detach FETCH_HEAD
fi

ZHANLU_COMMIT="$(git -C "${ZHANLU_DIR}" rev-parse HEAD)"
echo "ZHANLU_COMMIT: ${ZHANLU_COMMIT}"

if ! command -v bun >/dev/null 2>&1; then
  echo "Error: bun is required to build zhanlu CLI assets"
  exit 1
fi

echo "Installing zhanlu-vs dependencies"
(cd "${ZHANLU_DIR}" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bun install --frozen-lockfile || PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bun install)

echo "Building all opencode CLI targets"
(
  cd "${ZHANLU_DIR}/packages/opencode"
  unset KILO_RELEASE
  export KILO_VERSION="${ZHANLU_CLI_VERSION}"
  bun run build
)

smoke_test_linux_x64_baseline() {
  local binary="${ZHANLU_DIR}/packages/opencode/dist/@kilocode/cli-linux-x64-baseline/bin/zl"

  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64)
      echo "Running smoke test: ${binary} --version"
      "${binary}" --version
      ;;
    *)
      echo "Skipping linux-x64-baseline smoke test on non-Linux x64 host"
      ;;
  esac
}

pack_cli_asset() {
  local package_name="$1"
  local output_name="$2"
  local binary_name="$3"
  local bin_dir="${ZHANLU_DIR}/packages/opencode/dist/${package_name}/bin"
  local binary_path="${bin_dir}/${binary_name}"
  local tmp_dir
  local archive_path

  if [[ ! -f "${binary_path}" ]]; then
    echo "Error: missing CLI binary: ${binary_path}"
    exit 1
  fi
  if [[ ! -d "${bin_dir}/tree-sitter" ]]; then
    echo "Error: missing tree-sitter wasm directory: ${bin_dir}/tree-sitter"
    exit 1
  fi

  tmp_dir="$(mktemp -d)"
  archive_path="${SCRIPT_DIR}/assets/${output_name}"
  rm -f "${archive_path}"

  (cd "${bin_dir}" && tar --exclude='*.map' -cf - .) | (cd "${tmp_dir}" && tar -xf -)
  if find "${tmp_dir}" -name '*.map' -print -quit | grep -q .; then
    echo "Error: source maps leaked into ${output_name}"
    rm -rf "${tmp_dir}"
    exit 1
  fi

  (cd "${tmp_dir}" && zip -qr "${archive_path}" .)
  rm -rf "${tmp_dir}"
  echo "Created ${archive_path}"
}

mkdir -p assets
rm -f \
  "assets/zhanlu-cli-win32-x64-baseline-${RELEASE_VERSION}.zip" \
  "assets/zhanlu-cli-linux-x64-baseline-${RELEASE_VERSION}.zip" \
  "assets/zhanlu-cli-linux-x64-musl-${RELEASE_VERSION}.zip" \
  "assets/zhanlu-cli-linux-x64-baseline-musl-${RELEASE_VERSION}.zip" \
  "assets/zhanlu-cli-linux-arm64-musl-${RELEASE_VERSION}.zip"

smoke_test_linux_x64_baseline

pack_cli_asset "@kilocode/cli-windows-x64-baseline" "zhanlu-cli-win32-x64-baseline-${RELEASE_VERSION}.zip" "zl.exe"
pack_cli_asset "@kilocode/cli-linux-x64-baseline" "zhanlu-cli-linux-x64-baseline-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@kilocode/cli-linux-x64-musl" "zhanlu-cli-linux-x64-musl-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@kilocode/cli-linux-x64-baseline-musl" "zhanlu-cli-linux-x64-baseline-musl-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@kilocode/cli-linux-arm64-musl" "zhanlu-cli-linux-arm64-musl-${RELEASE_VERSION}.zip" "zl"

./prepare_checksums.sh
