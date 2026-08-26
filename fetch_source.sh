#!/usr/bin/env bash
# shellcheck disable=SC2129
# Fetch Source Code from Private Repository
# 从私有仓库获取所有源代码和构建脚本

set -e

# 保存当前目录
_CURRENT_DIR="$(pwd)"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_REPO_URL="${SOURCE_REPO_URL:-https://github.com/village-way/zhanlu-code.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-develop}"
# zhanlu_change - platform fan-out may pin the exact zhanlu-code commit resolved during release preparation
REQUESTED_SOURCE_COMMIT="${SOURCE_COMMIT:-}"
SOURCE_DIR="${_SCRIPT_DIR}/.source-repo"

# zhanlu_change start - customer deliveries never follow an unpinned branch from a direct workflow invocation
if [[ -n "${REQUESTED_SOURCE_COMMIT}" && ! "${REQUESTED_SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: SOURCE_COMMIT must be an exact 40-character Git SHA" >&2
    exit 1
fi
if [[ "${ZHANLU_DELIVERY_PROFILE:-default}" != "default" ]]; then
    if [[ -z "${REQUESTED_SOURCE_COMMIT}" ]]; then
        echo "Error: non-default delivery profiles require a pinned SOURCE_COMMIT" >&2
        exit 1
    fi
    if [[ ! "${ZHANLU_DELIVERY_PROFILE_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: non-default delivery profiles require a SHA-256 ZHANLU_DELIVERY_PROFILE_DIGEST" >&2
        exit 1
    fi
    if [[ -z "${ASSETS_REPOSITORY:-}" ]]; then
        echo "Error: non-default delivery profiles require an allowlisted ASSETS_REPOSITORY" >&2
        exit 1
    fi
fi
# zhanlu_change end

# 如果提供了 GitHub token，则将 token 嵌入到 URL 中
# 这对于访问私有仓库是必需的
if [[ -n "${ZHANLU_GITHUB_TOKEN}" ]]; then
    # 将 https://github.com/user/repo.git 转换为 https://token@github.com/user/repo.git
    SOURCE_REPO_URL="${SOURCE_REPO_URL/https:\/\//https://${ZHANLU_GITHUB_TOKEN}@}"
    echo "Using GitHub token for authentication (private repository)"
    
    # 配置 Git credential helper 以避免交互式密码提示
    git config --global credential.helper store
    # 禁用交互式提示
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS=/bin/echo
fi

echo "=== Source Code Fetching Script ==="
# 安全地显示 URL（隐藏 token）
if [[ "${SOURCE_REPO_URL}" =~ ^https://.*@github\.com ]]; then
    # 如果 URL 包含 token，则隐藏它
    DISPLAY_URL="${SOURCE_REPO_URL/@*/@***}"
    echo "SOURCE_REPO_URL: ${DISPLAY_URL}"
else
    echo "SOURCE_REPO_URL: ${SOURCE_REPO_URL}"
fi
echo "SOURCE_BRANCH: ${SOURCE_BRANCH}"
echo "SOURCE_COMMIT: ${REQUESTED_SOURCE_COMMIT:-<resolve from branch>}" # zhanlu_change
echo "SOURCE_DIR: ${SOURCE_DIR}"

# git workaround for CI environments
if [[ "${CI_BUILD}" != "no" ]] || [[ -n "${GITHUB_ACTIONS}" ]]; then
  git config --global --add safe.directory "${SOURCE_DIR}"
  # 在 CI 环境中禁用交互式提示
  export GIT_TERMINAL_PROMPT=0
fi

# 清理旧目录（如果需要强制克隆）
if [[ "${SOURCE_FORCE_CLONE}" == "yes" ]] && [[ -d "${SOURCE_DIR}" ]]; then
    echo "Force clone enabled, removing existing directory..."
    rm -rf "${SOURCE_DIR}"
fi

# 克隆或更新仓库
if [[ -d "${SOURCE_DIR}/.git" ]]; then
    echo "Source repository already exists, updating..."
    cd "${SOURCE_DIR}"
    git config core.autocrlf false # zhanlu_change - preserve release-pinned Profile bytes on Windows
    
    # 更新 remote URL（如果提供了 token，需要更新）
    if [[ -n "${ZHANLU_GITHUB_TOKEN}" ]]; then
        git remote set-url origin "${SOURCE_REPO_URL}"
    fi
    
    # zhanlu_change start - prefer the pinned commit; retain branch-only compatibility
    SOURCE_FETCH_REF="${REQUESTED_SOURCE_COMMIT:-${SOURCE_BRANCH}}"
    GIT_TERMINAL_PROMPT=0 git fetch origin "${SOURCE_FETCH_REF}" || {
        echo "Error: Failed to fetch from origin. Check your token permissions."
        exit 1
    }
    if [[ -n "${REQUESTED_SOURCE_COMMIT}" ]]; then
        git checkout --detach FETCH_HEAD
    else
        git checkout "${SOURCE_BRANCH}" 2>/dev/null || git checkout -b "${SOURCE_BRANCH}" "origin/${SOURCE_BRANCH}"
        git reset --hard "origin/${SOURCE_BRANCH}"
    fi
    # zhanlu_change end
    
    SOURCE_COMMIT=$(git rev-parse HEAD)
    echo "Updated to commit: ${SOURCE_COMMIT}"
else
    echo "Cloning source repository..."
    mkdir -p "${SOURCE_DIR}"
    cd "${SOURCE_DIR}"
    
    git init -q
    git config core.autocrlf false # zhanlu_change - preserve release-pinned Profile bytes on Windows
    git remote add origin "${SOURCE_REPO_URL}"
    
    # 获取指定分支
    # zhanlu_change start - fetch a release-pinned commit when supplied
    SOURCE_FETCH_REF="${REQUESTED_SOURCE_COMMIT:-${SOURCE_BRANCH}}"
    echo "Fetching source ref: ${SOURCE_FETCH_REF}"
    GIT_TERMINAL_PROMPT=0 git fetch --depth 1 origin "${SOURCE_FETCH_REF}" || {
        echo "Error: Failed to clone repository. Check your token permissions."
        exit 1
    }
    git checkout FETCH_HEAD
    # zhanlu_change end
    
    SOURCE_COMMIT=$(git rev-parse HEAD)
    echo "Cloned at commit: ${SOURCE_COMMIT}"
fi

# zhanlu_change start - never continue when a remote returned a different commit than the release pin
if [[ -n "${REQUESTED_SOURCE_COMMIT}" && "${SOURCE_COMMIT}" != "${REQUESTED_SOURCE_COMMIT}" ]]; then
    echo "Error: fetched source commit ${SOURCE_COMMIT}, expected ${REQUESTED_SOURCE_COMMIT}"
    exit 1
fi
# zhanlu_change end

# 返回到工作目录
cd "${_SCRIPT_DIR}"

# 复制所有源代码文件到当前目录
echo ""
echo "=== Copying source files ==="

# 需要复制的目录列表
DIRS_TO_COPY=(
    "build"
    "dev"
    "docs"
    "delivery-profiles" # zhanlu_change - customer delivery profiles are source-owned build inputs
    "icons"
    "patches"
    "scripts"
    "src"
    "stores"
    "upstream"
)

# 复制目录
for dir in "${DIRS_TO_COPY[@]}"; do
    if [[ -d "${SOURCE_DIR}/${dir}" ]]; then
        echo "Copying ${dir}/..."
        rm -rf "${_SCRIPT_DIR}/${dir}"
        cp -r "${SOURCE_DIR}/${dir}" "${_SCRIPT_DIR}/"
    else
        echo "Warning: ${dir}/ not found in source repository"
    fi
done

# 需要复制的文件列表
FILES_TO_COPY=(
    "build.sh"
    "build_zhanlu_agent_resources.sh" # zhanlu_change - native Agent build entry is source-owned
    "build_cli.sh"
    "check_cron_or_pr.sh"
    "check_tags.sh"
    "create-release.sh"
    "get_pr.sh"
    "get_repo.sh"
    "get_zhanlu.sh"
    "get_zhanlu_loc.sh"
    "get_zhanlu_remote_exts.sh"
    "write_zhanlu_root_env.sh"
    "prepare_assets.sh"
    "prepare_checksums.sh"
    "prepare_src.sh"
    "prepare_zhanlu_cli_assets.sh" # zhanlu_change - copy standalone CLI compatibility asset builder
    "prepare_vscode.sh"
    "prepare_zhanlu.sh"
    "prepare_zhanlu_loc.sh"
    "prepare_zhanlu_remote_exts.sh"
    "product.json"
    "release.sh"
    "release_notes.md"
    "test_zhanlu_integration.sh"
    "test_zhanlu_loc_integration.sh"
    "test_zhanlu_remote_exts_integration.sh"
    "undo_telemetry.sh"
    "update_upstream.sh"
    "update_version.sh"
    "upload_sourcemaps.sh"
    "utils.sh"
    "version.sh"
    "announcements-builtin.json"
    "announcements-extra.json"
    "npmrc"
    ".git-msg"
    # zhanlu_change start - setup-node runs after this script, so Node must come from zhanlu-code
    ".nvmrc"
    # zhanlu_change end
    "BRANDING_GUIDE.md"
    "FIX_BUILD_ERROR.md"
    "FUNDING.json"
    "VSCODE_TECH_ANALYSIS.md"
    "ZHANLU_INTEGRATION_README.md"
)

# 复制文件
echo ""
echo "Copying individual files..."
for file in "${FILES_TO_COPY[@]}"; do
    if [[ -f "${SOURCE_DIR}/${file}" ]]; then
        echo "Copying ${file}..."
        cp "${SOURCE_DIR}/${file}" "${_SCRIPT_DIR}/"
    else
        echo "Warning: ${file} not found in source repository"
    fi
done

# 设置脚本可执行权限
echo ""
echo "Setting executable permissions..."
find "${_SCRIPT_DIR}" -type f -name "*.sh" -exec chmod +x {} \;

# zhanlu_change start - validate profile digest and allowlisted release target against the exact fetched commit
if [[ "${ZHANLU_DELIVERY_PROFILE:-default}" == "default" && -n "${GITHUB_ACTIONS:-}" && "${ASSETS_REPOSITORY:-${GITHUB_REPOSITORY:-}}" != "${GITHUB_REPOSITORY:-}" ]]; then
    echo "Error: default delivery may publish only to the workflow repository" >&2
    exit 1
elif [[ "${ZHANLU_DELIVERY_PROFILE:-default}" != "default" ]]; then
    EXPECTED_ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-}"
    # shellcheck disable=SC1091
    source "${_SCRIPT_DIR}/scripts/prepare_delivery_profile.sh"
    prepare_delivery_profile "${_SCRIPT_DIR}"
    if [[ -z "${EXPECTED_ASSETS_REPOSITORY}" || "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" != "${EXPECTED_ASSETS_REPOSITORY}" ]]; then
        echo "Error: delivery assets repository ${EXPECTED_ASSETS_REPOSITORY:-<missing>} does not match allowlisted profile target ${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" >&2
        cleanup_delivery_profile
        exit 1
    fi
    cleanup_delivery_profile
    unset ZHANLU_DELIVERY_PLUGINS_DIR ZHANLU_DELIVERY_STAGING_DIR
fi
# zhanlu_change end

# 显示摘要
echo ""
echo "=== Source Code Fetch Summary ==="
echo "SOURCE_COMMIT=\"${SOURCE_COMMIT}\""
echo "SOURCE_BRANCH=\"${SOURCE_BRANCH}\""
echo "ZHANLU_DELIVERY_PROFILE=\"${ZHANLU_DELIVERY_PROFILE:-default}\"" # zhanlu_change
echo "ZHANLU_DELIVERY_PROFILE_DIGEST=\"${ZHANLU_DELIVERY_PROFILE_DIGEST:-}\"" # zhanlu_change
echo "All source files copied successfully!"

# 导出环境变量（供后续脚本使用）
export SOURCE_COMMIT
export SOURCE_BRANCH
# zhanlu_change start - expose the pinned delivery inputs to every downstream packaging script
export ZHANLU_DELIVERY_PROFILE="${ZHANLU_DELIVERY_PROFILE:-default}"
export ZHANLU_DELIVERY_SOURCE_COMMIT="${SOURCE_COMMIT}"
export ZHANLU_DELIVERY_PROFILE_DIGEST="${ZHANLU_DELIVERY_PROFILE_DIGEST:-}"
# zhanlu_change end

# for GH actions / CI environments
if [[ "${GITHUB_ENV}" ]]; then
    echo "SOURCE_COMMIT=${SOURCE_COMMIT}" >> "${GITHUB_ENV}"
    echo "SOURCE_BRANCH=${SOURCE_BRANCH}" >> "${GITHUB_ENV}"
    echo "ZHANLU_DELIVERY_PROFILE=${ZHANLU_DELIVERY_PROFILE}" >> "${GITHUB_ENV}" # zhanlu_change
    echo "ZHANLU_DELIVERY_SOURCE_COMMIT=${SOURCE_COMMIT}" >> "${GITHUB_ENV}" # zhanlu_change
    echo "ZHANLU_DELIVERY_PROFILE_DIGEST=${ZHANLU_DELIVERY_PROFILE_DIGEST}" >> "${GITHUB_ENV}" # zhanlu_change
fi

echo ""
echo "=== Source Code Fetching Complete ==="
