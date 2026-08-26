# zhanlu_change - new file
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# zhanlu_change start - req-042 E1 builds compatibility CLI assets from the same core snapshot
ZHANLU_SOURCE_MODE="zhanlu-core"
ZHANLU_DIR="${SCRIPT_DIR}/vscode/zhanlu-agent"
# zhanlu_change end
RELEASE_VERSION="${RELEASE_VERSION:-}"

if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "Error: RELEASE_VERSION is required"
  exit 1
fi

ZHANLU_CLI_VERSION="${RELEASE_VERSION%-insider}"

# zhanlu_change start - every compatibility CLI target is assembled from one resolved Profile.
# The EXIT trap keeps the staging directory from leaking when a later target fails to build.
source "${SCRIPT_DIR}/scripts/prepare_delivery_profile.sh"
prepare_delivery_profile "${SCRIPT_DIR}"
trap cleanup_delivery_profile EXIT
# zhanlu_change end

echo "=== Zhanlu CLI Compatibility Asset Builder ==="
echo "ZHANLU_SOURCE_MODE: ${ZHANLU_SOURCE_MODE}"
echo "ZHANLU_DIR: ${ZHANLU_DIR}"
echo "RELEASE_VERSION: ${RELEASE_VERSION}"
echo "KILO_VERSION: ${ZHANLU_CLI_VERSION}"

# zhanlu_change start - validate the resolved core snapshot; no retired repository fallback
CORE_SOURCE_METADATA="${ZHANLU_DIR}/zhanlu-core-source.json"
if [[ ! -f "${ZHANLU_DIR}/packages/opencode/package.json" || ! -f "${CORE_SOURCE_METADATA}" ]]; then
  echo "Error: resolved zhanlu-core Agent workspace is incomplete; run get_repo.sh first"
  exit 1
fi
ZHANLU_COMMIT="$(jq -r 'select(.repository == "zhanlu-core") | .commit // empty' "${CORE_SOURCE_METADATA}")"
if [[ -z "${ZHANLU_COMMIT}" || "${ZHANLU_COMMIT}" != "${MS_COMMIT:-}" ]]; then
  echo "Error: zhanlu-core Agent source hash does not match MS_COMMIT"
  exit 1
fi
# zhanlu_change end
echo "ZHANLU_COMMIT: ${ZHANLU_COMMIT}"

if ! command -v bun >/dev/null 2>&1; then
  echo "Error: bun is required to build zhanlu CLI assets"
  exit 1
fi

echo "Installing Zhanlu Agent workspace dependencies"
(cd "${ZHANLU_DIR}" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bun install --frozen-lockfile || PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bun install)

echo "Building all opencode CLI targets"
(
  cd "${ZHANLU_DIR}/packages/opencode"
  unset KILO_RELEASE
  export KILO_VERSION="${ZHANLU_CLI_VERSION}"
  export ZHANLU_BUNDLE_CODEX_RUNTIME=0
  bun run build
)

# zhanlu_change start - reject cross-target Profile drift before archives are created
REFERENCE_BUNDLE_INDEX=""
while IFS= read -r bundle_index; do
  if [[ -z "${REFERENCE_BUNDLE_INDEX}" ]]; then
    REFERENCE_BUNDLE_INDEX="${bundle_index}"
  else
    cmp "${REFERENCE_BUNDLE_INDEX}" "${bundle_index}"
  fi
done < <(find "${ZHANLU_DIR}/packages/opencode/dist" -path '*/bin/zhanlu-plugins/bundle-index.json' -type f | sort)
if [[ -z "${REFERENCE_BUNDLE_INDEX}" ]]; then
  echo "Error: no CLI distribution contains zhanlu-plugins/bundle-index.json"
  exit 1
fi
# zhanlu_change end

smoke_test_linux_x64_baseline() {
  local binary="${ZHANLU_DIR}/packages/opencode/dist/@zhanlucode/zl-linux-x64-baseline/bin/zl"

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

pack_cli_asset "@zhanlucode/zl-windows-x64-baseline" "zhanlu-cli-win32-x64-baseline-${RELEASE_VERSION}.zip" "zl.exe"
pack_cli_asset "@zhanlucode/zl-linux-x64-baseline" "zhanlu-cli-linux-x64-baseline-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@zhanlucode/zl-linux-x64-musl" "zhanlu-cli-linux-x64-musl-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@zhanlucode/zl-linux-x64-baseline-musl" "zhanlu-cli-linux-x64-baseline-musl-${RELEASE_VERSION}.zip" "zl"
pack_cli_asset "@zhanlucode/zl-linux-arm64-musl" "zhanlu-cli-linux-arm64-musl-${RELEASE_VERSION}.zip" "zl"

./prepare_checksums.sh
cleanup_delivery_profile # zhanlu_change
